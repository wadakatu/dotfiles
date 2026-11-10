#!/usr/bin/env bash
# home/scripts/agent-resume.sh が、指示を渡して再開したタブを resume-pending.tsv に記録することを確かめる。
# CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/agent-resume.sh
# orca / sysctl は偽物。記録は pr-dispatch.sh が「再開したセッションに指示が入るまで、同じ worktree に
# 起動しない」ために読むので、再開を依頼したのに記録が無い、を作らないことを主に見る。
set -u
# shellcheck disable=SC2016  # '...' の中の $x は偽コマンドの変数

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/agent-resume.sh"
base=$(mktemp -d)
base=$(cd "$base" && pwd -P)
trap '[ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
CASE=""
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}

# ---- 偽のコマンド ----
mkdir -p "$base/bin"
# terminal create は、呼ばれた時点の記録を控えてから、create-response の中身を create-rc で返す。
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo "orca $*" >>"$FAKE/calls"
case "$1 $2" in
    "terminal create")
        cat "$STATE_DIR/resume-pending.tsv" >"$FAKE/pending-at-create" 2>/dev/null
        cat "$FAKE/create-response" 2>/dev/null
        exit "$(cat "$FAKE/create-rc" 2>/dev/null || echo 0)"
        ;;
    "worktree ps") cat "$FAKE/ps.json" ;;
    *) echo '{"ok":true}' ;;
esac
EOF
cat >"$base/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *kern.bootsessionuuid*) echo BOOT-NOW ;;
    *kern.boottime*) echo '{ sec = 1700000000, usec = 0 } Tue Nov 14 22:13:20 2023' ;;
esac
EOF
chmod +x "$base/bin"/*
export PATH="$base/bin:$PATH"
# 本物の orca に届くと、手元の Orca にタブを作ってしまう。偽物が先に効いていなければ止める。
for c in orca sysctl; do
    [ "$(command -v "$c")" = "$base/bin/$c" ] || { echo "偽の $c が効いていない。中止"; exit 1; }
done

export FAKE="$base/fake" CLAUDE_HOME="$base/claude"
export STATE_DIR="$base/state" DISPATCH_LOCK="$base/lock" DISPATCH_LOCK_WAIT=0 LAUNCH_INTERVAL=0
pending="$STATE_DIR/resume-pending.tsv"
wt="$base/wt"
wtid="repo::$wt"
mkdir -p "$wt"

reset() {
    rm -rf "$STATE_DIR" "$FAKE" "$CLAUDE_HOME"
    mkdir -p "$STATE_DIR/sessions" "$FAKE"
    : >"$FAKE/calls"
    echo '{"result":{"worktrees":[]}}' >"$FAKE/ps.json"
    created term_1 tab-1:leaf-1
}
created() { # created <handle> <paneKey>: terminal create が成功して返す中身
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","paneKey":"%s","worktreeId":"%s"}}}\n' "$1" "$2" "$wtid" >"$FAKE/create-response"
    echo 0 >"$FAKE/create-rc"
}
# mark <sid> <止まったときの状態>: 前の起動の印と、その状態になる会話記録を置く
mark() {
    local t="$base/transcript-$1.jsonl"
    case "$2" in
        work) echo '{"type":"user","message":{"content":"続けて"}}' >"$t" ;;
        question) echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion"}]}}' >"$t" ;;
        idle) echo '{"type":"assistant","message":{"content":[{"type":"text","text":"終わりました"}]}}' >"$t" ;;
    esac
    printf 'BOOT-OLD\t1\t%s\t%s\t%s\n' "$wtid" "$wt" "$t" >"$STATE_DIR/sessions/$1"
}
# needs_decision <sid>: Needs decision で会話が開いていない worktree と、その最後の対話セッション
needs_decision() {
    printf '{"result":{"worktrees":[{"worktreeId":"%s","path":"%s","isMainWorktree":false,"workspaceStatus":"needs-decision","liveTerminalCount":0}]}}\n' \
        "$wtid" "$wt" >"$FAKE/ps.json"
    local dir
    dir="$CLAUDE_HOME/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$dir"
    echo '{"entrypoint":"cli","type":"user","message":{"content":"x"}}' >"$dir/$1.jsonl"
}
run() { bash "$script" >"$base/out" 2>&1; }
rows() { [ "$(awk 'NF' "$pending" 2>/dev/null | wc -l | tr -d ' ')" = "$1" ]; }
# row_in <ファイル> <handle> <paneKey> <sid>: その行がある (時刻は見ない)
row_in() { awk -F'\t' -v h="$2" -v p="$3" -v w="$wtid" -v s="$4" '$1 == h && $2 == p && $3 == w && $4 == s { f = 1 } END { exit !f }' "$1"; }
called() { grep -qF -- "$1" "$FAKE/calls"; }
not_called() { ! grep -qF -- "$1" "$FAKE/calls"; }

CASE="作業の途中だったセッション"
reset
mark sid-1 work
run
check "タブを作る" called "terminal create --worktree id:$wtid"
check "指示を渡す再開にする" called "launch 'sid-1' 'work'"
check "タブを作る前に、handle の無い行がある" row_in "$FAKE/pending-at-create" - - sid-1
check "作れたら handle と paneKey が入る" row_in "$pending" term_1 tab-1:leaf-1 sid-1
check "行は 1 つ" rows 1
check "印は動かす" [ -f "$STATE_DIR/resumed/sid-1" ]

CASE="質問の答え待ちだったセッション"
reset
mark sid-1 question
run
check "指示を渡す再開にする" called "launch 'sid-1' 'question'"
check "記録する" row_in "$pending" term_1 tab-1:leaf-1 sid-1

CASE="手が空いていたセッション"
reset
mark sid-1 idle
run
check "タブは作る" called "launch 'sid-1' 'idle'"
check "記録しない (自分からは動かない)" rows 0
check "作る前にも書かない" [ ! -s "$FAKE/pending-at-create" ]

CASE="Orca が失敗を返す"
reset
mark sid-1 work
echo '{"ok":false,"error":{"code":"selector_not_found"}}' >"$FAKE/create-response"
echo 1 >"$FAKE/create-rc"
run
check "作る前には行がある" row_in "$FAKE/pending-at-create" - - sid-1
check "行を消す (タブは無い)" rows 0
check "失敗をログに出す" grep -q "failed to resume sid-1" "$base/out"
check "カードに知らせる" called "worktree set --worktree id:$wtid --unread"

CASE="Orca の返事が読めない"
reset
mark sid-1 work
: >"$FAKE/create-response"
echo 1 >"$FAKE/create-rc"
run
check "handle の無い行を残す (タブができたかもしれない)" row_in "$pending" - - sid-1
check "行は 1 つ" rows 1

CASE="作れたが handle が返らない"
reset
mark sid-1 work
echo '{"ok":true,"result":{}}' >"$FAKE/create-response"
run
check "handle の無い行を残す" row_in "$pending" - - sid-1
check "再開は成功として扱う" grep -q "resume sid-1 (work)" "$base/out"

CASE="同じ worktree に 2 つのセッション"
reset
mark sid-1 work
mark sid-2 question
run
check "1 つ目の行" row_in "$pending" term_1 tab-1:leaf-1 sid-1
check "2 つ目の行" row_in "$pending" term_1 tab-1:leaf-1 sid-2
check "行は 2 つ" rows 2

CASE="ほかの行は触らない"
reset
printf 'term_9\ttab-9:leaf-9\tother::/x\tsid-9\t1\n-\t-\tother::/y\tsid-8\t2\n' >"$pending"
# 同じセッションの、前に作れたタブの行。まだ指示が入っていないかもしれないので、後の失敗で消してはいけない。
printf 'term_7\ttab-7:leaf-7\t%s\tsid-1\t3\n' "$wtid" >>"$pending"
mark sid-1 work
echo '{"ok":false}' >"$FAKE/create-response"
echo 1 >"$FAKE/create-rc"
run
check "自分の行は消える" rows 3
check "同じセッションの handle のある行は残る" row_in "$pending" term_7 tab-7:leaf-7 sid-1
check "handle のある行は残る" grep -q '^term_9	tab-9:leaf-9	other::/x	sid-9	1$' "$pending"
check "別のセッションの handle の無い行は残る" grep -q '^-	-	other::/y	sid-8	2$' "$pending"

CASE="Needs decision の開き直し"
reset
needs_decision sid-3
run
check "タブを作る" called "launch 'sid-3' 'recheck'"
check "タブを作る前に、handle の無い行がある" row_in "$FAKE/pending-at-create" - - sid-3
check "作れたら handle と paneKey が入る" row_in "$pending" term_1 tab-1:leaf-1 sid-3
check "二度開かない印を付ける" grep -q "sid-3" "$STATE_DIR/orphans.tsv"

CASE="開き直しが、返事の読めない失敗を繰り返す"
reset
needs_decision sid-3
: >"$FAKE/create-response"
echo 1 >"$FAKE/create-rc"
run
run
run
check "毎回試す" [ "$(grep -c 'terminal create' "$FAKE/calls")" = 3 ]
check "handle の無い行は 1 つのまま" rows 1

CASE="記録を書けない"
reset
mark sid-1 work
mkdir "$pending" # ファイルのあるべき場所がディレクトリで、追記できない
run
check "タブを作らない" not_called "terminal create"
check "理由をログに出す" grep -q "再開の記録を書けない" "$base/out"
check "カードに知らせる" called "worktree set --worktree id:$wtid --unread"
rm -rf "$pending"

CASE="DRY_RUN"
reset
mark sid-1 work
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "タブを作らない" not_called "terminal create"
check "記録しない" rows 0
check "印は動かさない" [ -f "$STATE_DIR/sessions/sid-1" ]

[ "$fail" = 0 ] && echo "agent-resume: all checks passed"
exit "$fail"
