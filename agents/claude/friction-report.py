#!/usr/bin/python3
"""~/.claude/projects のセッションログから、N 日間の空振り・摩擦を数える。

使い方: python3 agents/claude/friction-report.py [日数=14] [--until YYYY-MM-DD]
        python3 agents/claude/friction-report.py --self-check

設定を変える前後で同じ数字を取り直して比べるための道具。--until を付けると、その日の 0 時 (JST) までの
N 日間を数える (既定は今まで)。期間の長さが違う回も比べられるよう、件数にはツール呼び出し 1,000 回あたりを添える。
判定は文言の一致に頼るので、Claude Code のメッセージが変わると黙って 0 になる。--self-check はその判定だけを確かめる。
"""

from __future__ import annotations

import argparse
import collections
import datetime
import glob
import json
import os
import re

ROOT = os.path.expanduser("~/.claude/projects")
JA = re.compile(r"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uff66-\uff9f]")  # かな・漢字・半角カナ
# 人の入力に見えるが、実際はハーネスやコマンドが差し込んだもの
BOILER = re.compile(r"^(This session is being continued|<bash-|<command-|<local-command|<task-notification|Caveat:"
                    r"|\[Request interrupted|<system-reminder|# auto memory|Generate a short git branch|Reply with"
                    r"|Name this chat|reply with OK|<user-prompt-submit-hook)")
BASH_SIGS = [
    ("no matches found", re.compile(r"no matches found")),
    ("command not found", re.compile(r"command not found")),
    ("bad substitution / unbound variable", re.compile(r"bad substitution|unbound variable")),
    ("No such file or directory", re.compile(r"[Nn]o such file or directory")),
]
CTX_BUCKETS = ("<100k", "100-200k", "200-300k", "300-400k", ">=400k")
JST = datetime.timezone(datetime.timedelta(hours=9))


def no_japanese(text: str) -> bool:
    # 英語の判定ではない。コードだけの応答も入り、中国語は日本語の側に入る
    return not JA.search(text)


def head_words(cmd: str) -> str:
    # 先頭の cd と VAR=... を飛ばし、オプションや引数が出るまでの 3 語まで (gh pr merge、git grep)
    cmd = re.sub(r"^(cd [^;&]+(&&|;)\s*)+", "", cmd.strip())
    cmd = re.sub(r"^([A-Za-z_]\w*=\S+\s*;?\s*)+", "", cmd)
    words = cmd.split()[:3]
    n = next((i for i, w in enumerate(words) if i and not re.fullmatch(r"[a-z][\w-]*", w)), len(words))
    return " ".join(words[:n])


def classify_denial(result: str, tool: str, inp: dict) -> tuple[str, str] | None:
    """拒否なら (原因, 内訳)、拒否でなければ None。

    拒否のメッセージは書き出しが決まっているので、書き出しで判定する。本文のどこかで探すと、
    ログを grep した Bash の出力まで拒否と数える。権限ルールの拒否はコマンド全文を挟むので、末尾は全文から探す。
    """
    r = result.lstrip()
    if r.startswith("The server-side auto mode classifier gave no verdict"):
        return "auto mode の分類器", "gave no verdict"
    if r.startswith("Permission for this action was denied by the Claude Code auto mode classifier"):
        m = re.search(r"Reason: (?:\[([^\]]+)\]|([^.(]+))", r[:600])
        return "auto mode の分類器", (m.group(1) or m.group(2)).strip()[:70] if m else "?"
    if re.match(r"PreToolUse:\S+ hook (error|blocking)", r):
        m = re.search(r"hook error: \[([^\]]+)\]|from command: \"?([^\s\"]+)", r[:600])
        return "hook", os.path.basename(m.group(1) or m.group(2)) if m else "?"
    if r.startswith("Permission for this command was denied by a built-in Claude Code safety check"):
        return "組み込みの安全チェック", tool
    if r.startswith("Permission to ") and "has been denied" in r:
        detail = f"{tool} {head_words(str(inp.get('command') or ''))}".strip()
        return "権限ルール", detail + (" (don't ask mode)" if "don't ask mode" in r else "")
    if r.startswith("The user doesn't want to proceed"):
        return "ユーザーによる拒否", tool
    return None


def cwd_side(path: str, cwd: str) -> str:
    # 文字列の前方一致だと、隣の worktree (<cwd>-foo/...) まで中と数えるので、パスの区切りで比べる
    if not cwd or not path:
        return "cwd 不明"
    cwd = os.path.normpath(cwd)
    path = os.path.normpath(os.path.join(cwd, path))
    return "cwd の中" if os.path.commonpath([path, cwd]) == cwd else "cwd の外"


def bash_sig(result: str) -> str:
    if result.strip() == "Exit code 1":
        return "exit 1 (出力なし)"
    for name, rx in BASH_SIGS:
        if rx.search(result):
            return name
    return "その他"


def ts(e: dict) -> float | None:
    try:
        return datetime.datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00")).timestamp()
    except (KeyError, AttributeError, ValueError):
        return None


def text_of(c) -> str:
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text") or "" if x.get("type") == "text" else text_of(x.get("content"))
                         for x in c if isinstance(x, dict))
    return ""


def is_human(e: dict) -> bool:
    if e.get("isMeta") or e.get("isCompactSummary") or e.get("isSidechain"):
        return False
    if e.get("promptSource") in ("system", "sdk") or (e.get("origin") or {}).get("kind") in ("peer", "task", "hook"):
        return False
    content = (e.get("message") or {}).get("content")
    if isinstance(content, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
        return False
    txt = text_of(content).strip()
    return bool(txt) and not BOILER.match(txt)


class Report:
    def __init__(self) -> None:
        self.c = collections.defaultdict(collections.Counter)
        self.sess = collections.defaultdict(collections.Counter)  # (project, session) -> human / en / long / compact
        self.tool_calls = 0

    def process(self, path: str, key: tuple[str, str], sub: bool, since: float, until: float) -> None:
        c, s = self.c, self.sess[key]
        pending = {}
        usage = {}  # 同じリクエストが複数行に記録されるので、最後の行の usage を採る
        for line in open(path, encoding="utf-8", errors="replace"):
            if line.startswith(('{"type":"api-request', '{"type":"file-history')):
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = ts(e)
            msg = e.get("message") or {}
            content = msg.get("content")
            if t is None or t < since:
                # 期間の直前の入力やツール呼び出しにも、期間内の応答や結果が続くので覚えておく
                if e.get("type") == "assistant" and isinstance(content, list):
                    pending.update((x.get("id"), (x.get("name"), x.get("input") or {}))
                                   for x in content if isinstance(x, dict) and x.get("type") == "tool_use")
                elif e.get("type") == "user" and not sub and is_human(e):
                    s["human"] += 1
                continue
            if t >= until:
                continue
            s["main"] |= not sub  # 期間内の行があるセッションだけを数える
            if e.get("type") == "system" and e.get("subtype") == "compact_boundary":
                c["compact"][str((e.get("compactMetadata") or {}).get("trigger"))] += 1
                s["compact"] += 1
            elif e.get("type") == "assistant":
                u = msg.get("usage")
                if u and msg.get("id") and msg.get("model") != "<synthetic>":
                    usage[(msg["id"], e.get("requestId"))] = u
                for x in content if isinstance(content, list) else []:
                    if not isinstance(x, dict):
                        continue
                    # <synthetic> は API エラーなどをハーネスが書いたもので、モデルの応答ではない
                    if (x.get("type") == "text" and not sub and msg.get("model") != "<synthetic>"
                            and len(x.get("text", "").strip()) >= 80):
                        s["long"] += 1
                        s["en"] += no_japanese(x["text"])
                    elif x.get("type") == "tool_use":
                        name, inp = x.get("name"), x.get("input") or {}
                        pending[x.get("id")] = (name, inp)
                        self.tool_calls += 1
                        if name == "Skill":
                            c["skill"][str(inp.get("skill"))] += 1
                        elif name == "Agent":
                            c["agent"][f"{inp.get('subagent_type') or '(既定)'} × model={inp.get('model') or '-'}"] += 1
                        elif name == "Read":
                            fp = str(inp.get("file_path") or "")
                            if "/memory/" in fp or ".claude-shared-memory/" in fp:
                                c["memory_read"][os.path.basename(fp)] += 1
            elif e.get("type") == "user" and isinstance(content, list) and any(
                    isinstance(x, dict) and x.get("type") == "tool_result" for x in content):
                for x in content:
                    if not (isinstance(x, dict) and x.get("type") == "tool_result"):
                        continue
                    name, inp = pending.pop(x.get("tool_use_id"), ("?", {}))
                    if not x.get("is_error"):
                        continue
                    r = text_of(x.get("content"))
                    denial = classify_denial(r, name, inp)
                    if denial:
                        c["denial"][denial[0]] += 1
                        c["denial:" + denial[0]][denial[1]] += 1
                    elif name in ("Edit", "Write") and "has not been read" in r:
                        where = cwd_side(str(inp.get("file_path") or ""), e.get("cwd") or "")
                        c["not_read"][f"{name} {where} ({'sub' if sub else 'main'})"] += 1
                    elif name == "Bash":
                        c["bash"][bash_sig(r)] += 1
            elif e.get("type") == "user" and not sub and is_human(e):
                s["human"] += 1
        # advisor を挟んだリクエストは、トップレベルが複数回の呼び出しの合算になるので iterations ごとに数える
        for u in (it for u in usage.values() for it in u.get("iterations") or [u] if it.get("type") != "advisor_message"):
            cr = u.get("cache_read_input_tokens") or 0
            ctx = (u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) + cr
            b = CTX_BUCKETS[min(int(ctx // 100_000), 4)]
            kind = "sub" if sub else "main"
            c["ctx:" + kind][b] += 1
            c["ctx_read:" + kind][b] += cr

    def print(self, since: float, until: float) -> None:
        c = self.c

        def n(v: int) -> str:  # 件数と、ツール呼び出し 1,000 回あたり
            return f"{v:6,} {v * 1000 / (self.tool_calls or 1):6.2f}/1k"

        def total(v: int) -> str:
            return f"計 {v:,}、{v * 1000 / (self.tool_calls or 1):.2f}/1k"

        human = [s for s in self.sess.values() if s["human"] and s["main"]]
        en, long_ = sum(s["en"] for s in human), sum(s["long"] for s in human)
        since_s, until_s = (datetime.datetime.fromtimestamp(x, JST).strftime("%Y-%m-%d %H:%M") for x in (since, until))
        print(f"期間: {since_s} 〜 {until_s} (JST)")
        print(f"セッション {sum(s['main'] for s in self.sess.values())} 本 (人が入力したもの {len(human)} 本)、"
              f"ツール呼び出し {self.tool_calls:,} 回 (/1k の分母)")

        print("\n== 日本語の文字を含まない応答 (80 字以上。人が入力したセッションのメインスレッドの text ブロック)")
        print(f"  {en:,} / {long_:,} ({en / (long_ or 1):.1%})、3 個以上出たセッション {sum(s['en'] >= 3 for s in human)} 本")

        print(f"\n== ツール呼び出しの拒否 ({total(sum(c['denial'].values()))})")
        for cause, v in c["denial"].most_common():
            print(f"  {n(v)} {cause}")
            for k, w in c["denial:" + cause].most_common(10):
                print(f"    {n(w)} {k}")

        print(f"\n== Edit / Write の has not been read ({total(sum(c['not_read'].values()))})")
        for k, v in c["not_read"].most_common():
            print(f"  {n(v)} {k}")

        failures = {k: v for k, v in c["bash"].items() if k != "exit 1 (出力なし)"}
        print(f"\n== Bash の失敗 ({total(sum(failures.values()))})")
        for k, v in sorted(failures.items(), key=lambda kv: -kv[1]):
            print(f"  {n(v)} {k}")
        print(f"  {n(c['bash']['exit 1 (出力なし)'])} exit 1 (出力なし。失敗に数えない別枠)")

        print("\n== compaction")
        for k in ("auto", "manual"):
            print(f"  {n(c['compact'][k])} {k}")
        print(f"  5 回以上のセッション {sum(s['compact'] >= 5 for s in self.sess.values())} 本")

        print("\n== リクエストあたりの文脈 (件数 / cache read トークン)")
        for kind in ("main", "sub"):
            print(f"  {kind}")
            for b in CTX_BUCKETS:
                print(f"    {b:9} {c['ctx:' + kind][b]:7,} {c['ctx_read:' + kind][b]:15,}")

        for title, k in (("Skill の呼び出し", "skill"), ("Agent の呼び出し (subagent_type × model 指定)", "agent"),
                         ("メモリファイルの Read", "memory_read")):
            print(f"\n== {title} ({total(sum(c[k].values()))})")
            for name, v in c[k].most_common(15):
                print(f"  {n(v)} {name}")


def self_check() -> None:
    assert no_japanese("The tests pass and the PR is ready for review, so I will push the branch now and report.")
    assert not no_japanese("テストが通ったので push します。The PR is ready for review and the branch is pushed.")
    assert not no_japanese("Fixed the bug in 設定 loading, the rest of this sentence is in English only.")
    cases = [
        ("Permission for this action was denied by the Claude Code auto mode classifier. Reason: [Git Destructive]. If",
         "Bash", {}, ("auto mode の分類器", "Git Destructive")),
        ("Permission for this action was denied by the Claude Code auto mode classifier. Reason: Blocked by classifier. If",
         "Bash", {}, ("auto mode の分類器", "Blocked by classifier")),
        ("PreToolUse:Bash hook error: [~/.claude/hooks/branch-guard.sh]: branch-guard: HEAD is on protected branch",
         "Bash", {}, ("hook", "branch-guard.sh")),
        ("Permission for this command was denied by a built-in Claude Code safety check, not by the user.",
         "Bash", {}, ("組み込みの安全チェック", "Bash")),
        ("Permission to use Bash has been denied because Claude Code is running in don't ask mode.",
         "Bash", {"command": "cd /x && FOO=1 gh pr merge 1"}, ("権限ルール", "Bash gh pr merge (don't ask mode)")),
        ("Permission to use Bash with command grep -rn \"X\" .env has been denied.",
         "Bash", {"command": "grep -rn \"X\" .env"}, ("権限ルール", "Bash grep")),
        ("Permission to read /a/.env has been denied.", "Read", {}, ("権限ルール", "Read")),
        ("The server-side auto mode classifier gave no verdict (the response ended before its verdict arrived)",
         "Edit", {}, ("auto mode の分類器", "gave no verdict")),
        ("The user doesn't want to proceed with this tool use.", "AskUserQuestion", {}, ("ユーザーによる拒否", "AskUserQuestion")),
    ]
    for r, tool, inp, want in cases:
        assert classify_denial(r, tool, inp) == want, (r, classify_denial(r, tool, inp))
    long_cmd = "rg -n " + "x" * 700
    assert classify_denial(f"Permission to use Bash with command {long_cmd} has been denied.", "Bash",
                           {"command": long_cmd}) == ("権限ルール", "Bash rg")
    assert classify_denial("Exit code 1\nfoo", "Bash", {}) is None
    assert classify_denial("Exit code 0\nlog.jsonl: The user doesn't want to proceed / has been denied", "Bash", {}) is None
    assert classify_denial("Exit code 1\nlog.jsonl: PreToolUse:Bash hook error: [~/.claude/hooks/branch-guard.sh]",
                           "Bash", {}) is None
    assert cwd_side("/w/app/x.php", "/w/app/") == "cwd の中"
    assert cwd_side("/w/app-2/x.php", "/w/app") == "cwd の外"
    assert cwd_side("src/x.php", "/w/app") == "cwd の中" and cwd_side("../app-2/x.php", "/w/app") == "cwd の外"
    assert cwd_side("/w/app/x.php", "") == "cwd 不明"
    assert bash_sig("Exit code 1") == "exit 1 (出力なし)"
    assert bash_sig("Exit code 1\n(eval):1: no matches found: *.txt") == "no matches found"
    assert bash_sig("Exit code 1\nsome output") == "その他"
    print("self-check ok")


def main() -> None:
    ap = argparse.ArgumentParser(description="セッションログから N 日間の空振り・摩擦を数える")
    ap.add_argument("days", nargs="?", type=int, default=14)
    ap.add_argument("--until", type=datetime.date.fromisoformat, help="この日の 0 時 (JST) まで。既定は今")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()
    if args.self_check:
        return self_check()
    end = (datetime.datetime.combine(args.until, datetime.time(), JST) if args.until
           else datetime.datetime.now(JST))
    since, until = (end - datetime.timedelta(days=args.days)).timestamp(), end.timestamp()
    rep = Report()
    # サブエージェントのログは <project>/<session>/subagents/ の下。親のログが期間外でも、子だけ期間内に書かれることがある
    for path in glob.glob(f"{ROOT}/*/*.jsonl") + glob.glob(f"{ROOT}/*/*/subagents/**/*.jsonl", recursive=True):
        if os.path.getmtime(path) < since:
            continue
        proj, rest = os.path.relpath(path, ROOT).split("/", 1)
        sub = "/subagents/" in path
        rep.process(path, (proj, rest.split("/")[0].removesuffix(".jsonl")), sub, since, until)
    rep.print(since, until)


if __name__ == "__main__":
    main()
