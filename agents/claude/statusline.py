#!/usr/bin/python3
"""Claude Code のステータスライン (2行表示)。

stdin にセッション情報の JSON が渡され、stdout に出したものがそのまま
画面下部に表示される。1 echo = 1行。

実装方針:
- 外部依存なし。shebang を `env python3` ではなく macOS 標準の `/usr/bin/python3`
  に固定してあるのは、statusLine が起動するシェルで PATH（nix profile / mise shim）
  が揃っている保証がないため。同じ理由で jq も使わない。
  単一プロセスで済むので bash + jq より起動も速い。
- git はリポジトリが大きいと遅いので session_id ごとに5秒キャッシュする。
  プロセス ID をキーにするとキャッシュが毎回ミスするので使わない。
- 端末幅は tput cols では取れない (Claude Code が stdout を横取りするため)。
  Claude Code が渡してくる COLUMNS 環境変数を読む。
- 何があっても例外で落とさない。落ちるとステータスラインが空になる。

表示:
  ◆ Opus 5 high · ~/www/dotfiles · main ↑2 +2 ~5 ?1
  ███████░░░ 68% · $1.24 · 12m · +156/-23
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# --- ANSI カラー -----------------------------------------------------------
# Nerd Font は入っていない (JetBrains Mono) ので、グリフは Unicode の
# ブロック要素・矢印など素の等幅フォントに含まれるものだけを使う。
RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
CYAN = "\033[36m"
GRAY = "\033[90m"

SEP = f"{GRAY} · {RESET}"
BAR_WIDTH = 10
GIT_CACHE_TTL = 5.0
GIT_TIMEOUT = 2.0

_ANSI_RE = re.compile(r"\033\[[0-9;]*m|\033\][^\a]*\a")


def paint(text: str, *codes: str) -> str:
    return f"{''.join(codes)}{text}{RESET}" if codes else text


def vis_len(text: str) -> int:
    """ANSI エスケープを除いた表示上の文字数。"""
    return len(_ANSI_RE.sub("", text))


# --- git -------------------------------------------------------------------
def _git_status(cwd: str) -> dict:
    """porcelain=v2 --branch を1回だけ叩いて、必要な情報をまとめて取る。

    ブランチ名・ahead/behind・staged/modified/untracked/conflict が
    この1コマンドで揃うので、git を複数回呼ぶより速い。
    """
    result = subprocess.run(
        ["git", "status", "--porcelain=v2", "--branch", "--untracked-files=normal"],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=GIT_TIMEOUT,
    )
    if result.returncode != 0:
        return {}

    info = {
        "branch": "",
        "ahead": 0,
        "behind": 0,
        "staged": 0,
        "modified": 0,
        "untracked": 0,
        "conflict": 0,
    }
    for line in result.stdout.splitlines():
        if line.startswith("# branch.head "):
            head = line[len("# branch.head "):]
            info["branch"] = head
        elif line.startswith("# branch.oid ") and not info["branch"]:
            info["branch"] = line[len("# branch.oid "):][:7]
        elif line.startswith("# branch.ab "):
            for token in line[len("# branch.ab "):].split():
                if token.startswith("+"):
                    info["ahead"] = int(token[1:])
                elif token.startswith("-"):
                    info["behind"] = int(token[1:])
        elif line.startswith("? "):
            info["untracked"] += 1
        elif line.startswith("u "):
            info["conflict"] += 1
        elif line[:2] in ("1 ", "2 "):
            # "1 XY ..." の XY が index/worktree の状態。'.' は変更なし。
            xy = line[2:4]
            if xy[0] != ".":
                info["staged"] += 1
            if xy[1] != ".":
                info["modified"] += 1

    if info["branch"] == "(detached)":
        info["branch"] = "detached"
    return info


def git_info(cwd: str, session_id: str) -> dict:
    """git 情報を5秒キャッシュ付きで取得する。"""
    key = hashlib.md5(f"{session_id}:{cwd}".encode()).hexdigest()[:16]
    cache_path = os.path.join(tempfile.gettempdir(), f"cc-statusline-{key}.json")

    try:
        if time.time() - os.path.getmtime(cache_path) < GIT_CACHE_TTL:
            with open(cache_path) as f:
                return json.load(f)
    except (OSError, ValueError):
        pass

    try:
        info = _git_status(cwd)
    except (OSError, subprocess.SubprocessError):
        info = {}

    try:
        # 一時ファイル経由で置換し、並行セッションが壊れた JSON を読まないようにする。
        tmp_path = f"{cache_path}.{os.getpid()}"
        with open(tmp_path, "w") as f:
            json.dump(info, f)
        os.replace(tmp_path, cache_path)
    except OSError:
        pass

    return info


# --- 整形 ------------------------------------------------------------------
def fmt_dir(cwd: str, project_dir: str) -> str:
    """ホーム相対のパス。cwd が project_dir から外れていれば cwd を出す。"""
    home = os.path.expanduser("~")
    base = cwd or project_dir or home

    if project_dir and cwd and cwd != project_dir:
        rel = os.path.relpath(cwd, project_dir)
        if not rel.startswith(".."):
            base = os.path.join(project_dir, rel)

    if base.startswith(home):
        base = "~" + base[len(home):]
    return base


def fmt_duration(ms: float) -> str:
    total = int(ms // 1000)
    if total < 60:
        return f"{total}s"
    minutes, _ = divmod(total, 60)
    if minutes < 60:
        return f"{minutes}m"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


def pct_color(pct: float, warn: float, danger: float) -> str:
    if pct >= danger:
        return RED
    if pct >= warn:
        return YELLOW
    return GREEN


def context_bar(pct: float) -> str:
    filled = max(0, min(BAR_WIDTH, int(round(pct / (100 / BAR_WIDTH)))))
    bar = "█" * filled + "░" * (BAR_WIDTH - filled)
    color = pct_color(pct, 70, 90)
    return f"{paint(bar, color)} {paint(f'{pct:.0f}%', color)}"


def fit(segments: list[tuple[str, bool]], width: int) -> str:
    """幅に収まるまで、末尾から optional なセグメントを落としていく。

    segments は (表示文字列, 必須か) のリスト。
    """
    while True:
        line = SEP.join(text for text, _ in segments)
        if vis_len(line) <= width or all(required for _, required in segments):
            return line
        for i in range(len(segments) - 1, -1, -1):
            if not segments[i][1]:
                del segments[i]
                break


def build(data: dict, width: int) -> list[str]:
    model = data.get("model") or {}
    workspace = data.get("workspace") or {}
    cost = data.get("cost") or {}
    ctx = data.get("context_window") or {}

    cwd = workspace.get("current_dir") or data.get("cwd") or os.getcwd()
    project_dir = workspace.get("project_dir") or cwd

    # --- 1行目 ---
    line1: list[tuple[str, bool]] = []

    model_name = model.get("display_name") or "claude"
    head = f"{paint('◆', MAGENTA)} {paint(model_name, BOLD, CYAN)}"
    effort = ((data.get("effort") or {}).get("level") or "").strip()
    if effort and effort != "medium":
        head += f" {paint(effort, DIM)}"
    if data.get("fast_mode"):
        head += f" {paint('fast', DIM, YELLOW)}"
    line1.append((head, True))

    line1.append((paint(fmt_dir(cwd, project_dir), BLUE), True))

    git = git_info(cwd, data.get("session_id") or "nosession")
    if git.get("branch"):
        parts = [paint(git["branch"], GREEN)]
        worktree = workspace.get("git_worktree") or (data.get("worktree") or {}).get("name")
        if worktree:
            parts.append(paint(f"[wt:{worktree}]", MAGENTA))
        if git.get("ahead"):
            parts.append(paint(f"↑{git['ahead']}", CYAN))
        if git.get("behind"):
            parts.append(paint(f"↓{git['behind']}", CYAN))
        if git.get("staged"):
            parts.append(paint(f"+{git['staged']}", GREEN))
        if git.get("modified"):
            parts.append(paint(f"~{git['modified']}", YELLOW))
        if git.get("untracked"):
            parts.append(paint(f"?{git['untracked']}", GRAY))
        if git.get("conflict"):
            parts.append(paint(f"!{git['conflict']}", RED))
        line1.append((" ".join(parts), False))

    # --- 2行目 ---
    line2: list[tuple[str, bool]] = []

    used = ctx.get("used_percentage")
    if used is None:
        line2.append((f"{paint('░' * BAR_WIDTH, GRAY)} {paint('--%', GRAY)}", True))
    else:
        line2.append((context_bar(float(used)), True))

    total_cost = cost.get("total_cost_usd")
    if total_cost:
        line2.append((paint(f"${float(total_cost):.2f}", YELLOW), False))

    duration = cost.get("total_duration_ms")
    if duration:
        line2.append((paint(fmt_duration(float(duration)), DIM), False))

    added = int(cost.get("total_lines_added") or 0)
    removed = int(cost.get("total_lines_removed") or 0)
    if added or removed:
        line2.append((f"{paint(f'+{added}', GREEN)}{paint('/', GRAY)}{paint(f'-{removed}', RED)}", False))

    return [fit(line1, width), fit(line2, width)]


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return

    try:
        width = int(os.environ.get("COLUMNS") or 120)
    except ValueError:
        width = 120
    width = max(40, width - 2)

    try:
        for line in build(data, width):
            print(line)
    except Exception:
        # 何かあっても最低限モデル名だけは出す。
        model = ((data.get("model") or {}).get("display_name")) or "claude"
        print(f"◆ {model}")


if __name__ == "__main__":
    main()
