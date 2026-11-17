#!/usr/bin/env bash
# home/scripts/agent-gc.sh の判定 (judge)、入力欄が空かの判定 (prompt-empty)、stop の止め方と台帳を確かめる。CI と手元で回す。
#   bash tests/agent-gc.sh
# stop の材料 (ps・lsof・sysctl・orca・osascript・sleep) は偽物。止めないべきものに /exit を送らないことと、
# 止めたものの戻し方に、再開のときに次のターンとして実行される引数を入れないことを主に見る。
# shellcheck disable=SC2016,SC2329  # '...' の中の $x は偽コマンドの変数。check に渡す関数は間接的に呼ぶ
set -u

script="$(cd "$(dirname "$0")/.." && pwd)/home/scripts/agent-gc.sh"
base=$(mktemp -d)
base=$(cd "$base" && pwd -P)
trap '[ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0

# 状態は全部この下に置かせる。向け忘れると、実際の台帳・ログ・セッションの記録を読み書きする。
# HOME は替えない (mise の shim の jq が設定を信頼しなくなり、動かなくなる)。
export STATE_ROOT="$base/root" CLEANUP_KEEP="$base/keep" CLAUDE_CONFIG_DIR="$base/claude" \
    LOG="$base/agent-gc.log" FAKE="$base/fake"
unset STATE_DIR EXCLUDE_RE DRY_RUN IDLE_H IDLE_WARN_H
: >"$CLEANUP_KEEP"

# 候補になる材料。各ケースはここから 1 か所だけ変える。
base_row='{"pid":1,"agent":"claude","readable":true,"status":"idle","idle_sec":90000,"pressure":1,"path":"/w/a","bg_shell":false,
       "orca":{"ok":true,"found":true,"state":"done","workspace_status":"in-review","sub_states":[]}}'

judge() { # judge <説明> <期待する reason (候補なら null)> <jq で base_row に当てる変更>
    local got
    got=$(jq -c "$3" <<<"$base_row" | EXCLUDE_RE='^/w/skip' bash "$script" judge | jq -r '.reason // "null"')
    [ "$got" = "$2" ] || { echo "FAIL judge: $1 (want $2, got $got)"; fail=1; }
}

judge "候補" null '.'
judge "Codex も同じ規則" null '.agent = "codex"'
judge "pressure WARN なら 6h で候補" null '.idle_sec = 25200 | .pressure = 2'
judge "pressure NORMAL なら 7h は残す" "idle 7h" '.idle_sec = 25200'
judge "読めない" unreadable '.readable = false'
judge "readable が無い" unreadable 'del(.readable)'
judge "busy" "status=busy" '.status = "busy"'
judge "waiting" "status=waiting" '.status = "waiting"'
judge "idle_sec が無い" "idle 0h" '.idle_sec = null'
judge "Orca に届かない" orca-unreachable '.orca.ok = false'
judge "Orca にペインが無い" not-in-orca '.orca.found = false'
judge "Orca が working" "orca working" '.orca.state = "working"'
judge "subagent が working" "orca-sub working" '.orca.sub_states = ["idle", "working"]'
judge "subagent の状態が欠けていたら残す" "orca-sub null" '.orca.sub_states = [null, "working"]'
judge "subagent が idle と done だけなら候補" null '.orca.sub_states = ["idle", "done"]'
judge "workspace_status が無い" orca-incomplete 'del(.orca.workspace_status)'
judge "needs-decision" needs-decision '.orca.workspace_status = "needs-decision"'
judge "子孫にシェルが居る" bg-shell '.bg_shell = true'
judge "bg_shell が無い" bg-unknown 'del(.bg_shell)'
judge "status=shell も残す" "status=shell" '.status = "shell"'
judge "EXCLUDE_RE" excluded '.path = "/w/skip/x"'

prompt() { # prompt <説明> <agent> <0=空 / 1=空でない> <端末の末尾>
    printf '%s\n' "$4" | bash "$script" prompt-empty "$2"
    [ $? = "$3" ] || { echo "FAIL prompt-empty: $1"; fail=1; }
}

prompt "Claude 空" claude 0 $'❯ 前の依頼\n✻ Worked for 3m\n────\n❯ \n────\n  ◆ Opus'
prompt "Claude 書きかけ" claude 1 $'────\n❯ あとでこれを\n────'
prompt "Claude 2 行目に書きかけ" claude 1 $'────\n❯ \n  あとでこれを\n────'
prompt "Claude 罫線が無い" claude 1 $'❯'
prompt "Claude シェルに戻った" claude 1 $'Resume this session with:\n~/www/dev [ master]'
prompt "Codex 空" codex 0 $'  Worked for 3m\n› Ask Codex to do anything\n  ? for shortcuts'
prompt "Codex 書きかけ" codex 1 $'› Ask Codex to do anything\n› 次はテストを'
prompt "Codex 別の placeholder" codex 1 $'› Explain this codebase'
prompt "知らない agent" other 1 $'❯'

# ---- stop: 偽のコマンド ----
# プロセスは $FAKE/procs/<pid>/ のファイルで表す。exited があれば終わったもの。ppid が無ければ親は 1。
mkdir -p "$base/bin"
# 本物の ps と同じく、引数は空白で繋いだ 1 行で返す (argv の境界は残らない)。eww は引数の後ろに環境変数を並べる。
# 一覧は本物と同じく pid と ppid を右に寄せ、コマンド名は空白を含んだまま行末まで出す。
# -ww (戻し方を組むときに呼ばれる) は、on_ww があればそれを流してから返す (送る直前の確認より前に呼ばれたかを見る)。
cat >"$base/bin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "-axo pid=,ppid=,comm=" ]; then
    for d in "$FAKE"/procs/*; do
        [ -d "$d" ] && [ ! -f "$d/exited" ] && printf '%5s %5s %s\n' "${d##*/}" "$(cat "$d/ppid" 2>/dev/null || echo 1)" "$(cat "$d/comm")"
    done
    exit 0
fi
d="$FAKE/procs/${!#}"
[ -d "$d" ] && [ ! -f "$d/exited" ] || exit 1
case "$1" in
    eww) echo "$(cat "$d/args") $(cat "$d/env")" ;;
    -ww) [ ! -f "$d/on_ww" ] || bash "$d/on_ww"; cat "$d/args" ;;
    -o) cat "$d/lstart" ;;
    *) exit 1 ;;
esac
EOF
cat >"$base/bin/lsof" <<'EOF'
#!/usr/bin/env bash
p=$(sed -E 's/.*-p ([0-9]+).*/\1/' <<<"$*")
case "$*" in
    *"-d cwd"*) echo "n$(cat "$FAKE/procs/$p/cwd")" ;;
    *) echo "n$FAKE/codex/.codex/sessions/2026/rollout-$p.jsonl" ;;
esac
EOF
# send は送った端末を控え、stuck の無いプロセスを終わらせる。終わったプロセスの sessions/<pid>.json は本物と同じく消す
# (ID を /exit の前に控えていないと、戻し方から ID が落ちる)。
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
term=""
for a in "$@"; do [ "${prev:-}" = --terminal ] && term=$a; prev=$a; done
p=${term#h}
case "$1 $2" in
    "worktree ps")
        for d in "$FAKE"/procs/*; do [ -d "$d" ] && echo "${d##*/}"; done |
            jq -R '{paneKey: ("p" + .), state: "done"}' |
            jq -s '{result: {truncated: false, worktrees: [{workspaceStatus: "in-review", agents: .}]}}' ;;
    "terminal list")
        for d in "$FAKE"/procs/*; do [ -d "$d" ] && jq -n --arg h "h${d##*/}" --arg a "$(cat "$d/comm")" '{handle: $h, agentIdentity: $a}'; done |
            jq -s '{result: {terminals: .}}' ;;
    "terminal read")
        case "$(cat "$FAKE/procs/$p/comm")" in
            claude) tail='["❯ ", "────"]' ;;
            *) tail='["› Ask Codex to do anything"]' ;;
        esac
        [ ! -f "$FAKE/procs/$p/tail" ] || tail=$(cat "$FAKE/procs/$p/tail")
        jq -n --argjson t "$tail" '{result: {terminal: {source: "screen", draft: "", tail: $t}}}' ;;
    "terminal send")
        echo "$term" >>"$FAKE/sent"
        [ -f "$FAKE/procs/$p/stuck" ] || { touch "$FAKE/procs/$p/exited"; rm -f "$CLAUDE_CONFIG_DIR/sessions/$p.json"; }
        echo '{"ok":true}' ;;
    *) exit 1 ;;
esac
EOF
cat >"$base/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo 1
EOF
cat >"$base/bin/osascript" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >>"$FAKE/notified"
EOF
cat >"$base/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$base/bin"/*
export PATH="$base/bin:$PATH"
# 本物の orca に届くと、手元のセッションに /exit を送ってしまう。偽物が先に効いていなければ止める。
for c in ps lsof orca sysctl osascript sleep; do
    [ "$(command -v "$c")" = "$base/bin/$c" ] || { echo "偽の $c が効いていない。中止"; exit 1; }
done

CASE=""
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}
reset() {
    CASE=$1
    rm -rf "$FAKE" "$CLAUDE_CONFIG_DIR" "$STATE_ROOT" "$LOG"
    mkdir -p "$FAKE/procs" "$FAKE/codex/.codex/sessions/2026" "$CLAUDE_CONFIG_DIR/sessions"
    : >"$FAKE/sent"
    : >"$CLEANUP_KEEP"
}
lstart="Mon Nov 17 01:00:00 2026"
# 会話記録に 1 行足す。tx <sessionId> <JSON の 1 行>
tx() { mkdir -p "$CLAUDE_CONFIG_DIR/projects/x" && printf '%s\n' "$2" >>"$CLAUDE_CONFIG_DIR/projects/x/$1.jsonl"; }
# セッションでないプロセス (シェル・MCP のサーバ) を置く。child <pid> <ppid> <コマンド名>
child() { mkdir -p "$FAKE/procs/$1" && echo "$3" >"$FAKE/procs/$1/comm" && echo "$2" >"$FAKE/procs/$1/ppid"; }
# proc <pid> <agent> <cwd> <起動時の引数> [sessionId (- なら記録を置かない、空なら sessionId を書かない)]
# sessionId を書くときは、予約の呼び出しの無い会話記録も置く。
proc() {
    local d="$FAKE/procs/$1"
    mkdir -p "$d"
    echo "$2" >"$d/comm"
    echo "$3" >"$d/cwd"
    echo "$2${4:+ $4}" >"$d/args"
    echo "ORCA_PANE_KEY=p$1 ORCA_TERMINAL_HANDLE=h$1 ORCA_WORKTREE_ID=w" >"$d/env"
    echo "$lstart" >"$d/lstart"
    if [ "$2" = codex ]; then
        echo '{"type":"event_msg","timestamp":"2026-01-01T00:00:00.000Z","payload":{"type":"task_complete"}}' \
            >"$FAKE/codex/.codex/sessions/2026/rollout-$1.jsonl"
    elif [ "${5-}" != - ]; then
        # 100 時間前から idle
        jq -n --argjson pid "$1" --arg ls "$lstart" --arg cwd "$3" --arg sid "${5-}" \
            --argjson at "$((($(date +%s) - 360000) * 1000))" '
            {pid: $pid, procStart: $ls, kind: "interactive", status: "idle", statusUpdatedAt: $at, cwd: $cwd}
            + (if $sid == "" then {} else {sessionId: $sid} end)' >"$CLAUDE_CONFIG_DIR/sessions/$1.json"
        [ -z "${5-}" ] || tx "$5" '{"type":"user","message":{"role":"user","content":"hi"}}'
    fi
}
ledger="$STATE_ROOT/cleanup-ledger/ledger.tsv"
sent() { grep -qxF "h$1" "$FAKE/sent"; }
not_sent() { ! sent "$1"; }
sent_none() { [ ! -s "$FAKE/sent" ]; }
ledger_lines() { [ "$(cat "$ledger" 2>/dev/null | grep -c .)" = "$1" ]; }
absent() { [ -f "$ledger" ] && ! grep -qE "$1" "$ledger"; }
col() { awk -F'\t' -v c="$1" '{ print $c }' "$ledger"; }
# 台帳の戻し方を、cd・claude・codex を偽の関数にして eval し、受け取った引数を 1 行 1 つで出す。
# 引用の書き方 (bash の版で %q の出力が違う) に左右されずに、渡る引数だけを比べるため。
argv_of() {
    (
        cd() { printf 'cd\n%s\n' "$1"; }
        claude() { printf '%s\n' claude "$@"; }
        codex() { printf '%s\n' codex "$@"; }
        eval "$1"
    )
}
same() { [ "$1" = "$2" ] || { echo "  want: $(printf '%q ' "$2")"; echo "  got:  $(printf '%q ' "$1")"; return 1; }; }
check_restore() { # check_restore <説明> <期待する引数 (1 行 1 つ)>
    local got
    got=$(argv_of "$(col 5 | head -1)")
    [ "$got" = "$2" ] || { echo "FAIL [$CASE] $1"; same "$got" "$2"; fail=1; }
}
check_restore_at() { # check_restore_at <説明> <cwd> <期待する引数 (1 行 1 つ)>: 対象が「claude <cwd>」の行の戻し方
    local got
    got=$(argv_of "$(awk -F'\t' -v t="claude $2" '$3 == t { print $5 }' "$ledger" | head -1)")
    [ "$got" = "$3" ] || { echo "FAIL [$CASE] $1"; same "$got" "$3"; fail=1; }
}

# ---- stop: 台帳と戻し方 ----
reset "台帳に 1 行、戻し方は許可した引数だけ"
mkdir -p "$base/plug dir" "$base/p2"
# 位置引数の後ろの --effort max と --plugin-dir は指示の本文の一部として扱い、拾わない。
proc 101 claude /w/a "--plugin-dir $base/plug dir --plugin-dir=$base/p2 --model=opus --effort high --prefill https://example.test/p /some-command https://example.test/c --effort max --plugin-dir $base/p2" SID-1
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送る" sent 101
check "台帳に 1 行" ledger_lines 1
check "種類は session" [ "$(col 2)" = session ]
check "対象はエージェントと cwd" [ "$(col 3)" = "claude /w/a" ]
check "規則に idle と閾値" [ "$(col 4)" = "idle 100h >= 24h" ]
check "戻らないものに、resume で戻らない裏の作業" [ "$(col 6)" = "裏のコマンド・モニター・自分で間隔を決める /loop（在ったかは分からない）" ]
check_restore "戻し方は cd と、許可した引数だけと --resume ID (空白入りの値も 1 つの引数)" \
    "$(printf '%s\n' cd /w/a claude --plugin-dir "$base/plug dir" --plugin-dir "$base/p2" --model opus --effort high --resume SID-1)"
check "--prefill も位置引数も戻し方に入らない" absent 'prefill|some-command|example\.test'

# ID が無いと会話記録を引けず、予約を作ったかが分からない (sched-unknown)。
reset "Claude の ID が無ければ送らない"
proc 102 claude /w/b "" ""
bash "$script" stop 102 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "台帳に書かない" ledger_lines 0
check "ログに sched-unknown" grep -qF 'pid=102: sched-unknown' "$LOG"

reset "Codex は codex resume"
proc 201 codex /w/c "--model gpt"
bash "$script" stop 201 >/dev/null 2>&1
check "/exit を送る" sent 201
check "台帳に 1 行" ledger_lines 1
check "対象は codex と cwd" [ "$(col 3)" = "codex /w/c" ]
check_restore "codex resume" "$(printf '%s\n' cd /w/c codex resume)"
check "一覧から選ぶと書く" grep -qF '一覧から選ぶ' "$ledger"
# 対話の zsh は既定で # をコメントにしないので、貼ると注記が引数として渡る。
check "戻し方に # を使わない" absent '#'

reset "DRY_RUN は台帳に書かない"
proc 101 claude /w/a "" SID-1
DRY_RUN=1 bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "台帳に書かない" ledger_lines 0

reset "待ち時間のうちに終わらなかったものも、終了は未確認と書いて台帳に残す"
proc 101 claude /w/a "" SID-1
touch "$FAKE/procs/101/stuck"
bash "$script" stop 101 >/dev/null 2>&1
check "/exit は送る" sent 101
check "台帳に 1 行" ledger_lines 1
check "規則に未確認の印" [ "$(col 4)" = "idle 100h >= 24h (/exit 送信済み・終了は未確認)" ]
check_restore "戻し方は止まったものと同じ" "$(printf '%s\n' cd /w/a claude --resume SID-1)"
check "失敗をログに書く" grep -qF 'still running' "$LOG"

# ---- stop: 戻し方で再開したセッションを、次にまた止める (2 世代目) ----
# 戻し方は許可した引数を --resume の前に置く。手で --resume を前に打った起動でも、その値を読み飛ばして拾う。
reset "2 世代目も許可した引数が残る"
mkdir -p "$base/p2"
proc 111 claude /w/g1 "--resume OLD --plugin-dir $base/p2 --model opus" SID-G1
proc 112 claude /w/g2 "--plugin-dir $base/p2 --model opus --resume OLD" SID-G2
proc 113 claude /w/g3 "-r OLD --effort high" SID-G3
proc 114 claude /w/g4 "--resume OLD fix it --model evil" SID-G4
proc 115 claude /w/g5 "--resume --model opus" SID-G5
bash "$script" stop 111 112 113 114 115 >/dev/null 2>&1
check "台帳に 5 行" ledger_lines 5
check_restore_at "--resume <ID> の後ろの引数を拾う" /w/g1 "$(printf '%s\n' cd /w/g1 claude --plugin-dir "$base/p2" --model opus --resume SID-G1)"
check_restore_at "台帳が出した形 (--resume が最後) も同じ" /w/g2 "$(printf '%s\n' cd /w/g2 claude --plugin-dir "$base/p2" --model opus --resume SID-G2)"
check_restore_at "-r も読み飛ばす" /w/g3 "$(printf '%s\n' cd /w/g3 claude --effort high --resume SID-G3)"
check_restore_at "位置引数の後ろは今どおり拾わない" /w/g4 "$(printf '%s\n' cd /w/g4 claude --resume SID-G4)"
check_restore_at "- で始まる次のトークンは --resume の値にしない" /w/g5 "$(printf '%s\n' cd /w/g5 claude --model opus --resume SID-G5)"

reset "--model・--effort の値が空か - で始まるときは、その flag を付けない"
proc 121 claude /w/m1 "--model --effort high" SID-M1
proc 122 claude /w/m2 "--model= --effort=-x --model sonnet" SID-M2
bash "$script" stop 121 122 >/dev/null 2>&1
check_restore_at "値の無い --model は落とし、次の flag から読む" /w/m1 "$(printf '%s\n' cd /w/m1 claude --effort high --resume SID-M1)"
check_restore_at "空と - で始まる値は落とす" /w/m2 "$(printf '%s\n' cd /w/m2 claude --model sonnet --resume SID-M2)"

# ---- stop: cwd が分からないセッションは、リストに当たるか判定できないので止めない ----
reset "cwd が空・絶対パスでないものは止めない"
proc 131 claude "" "" SID-C1
proc 132 claude rel/x "" SID-C2
bash "$script" stop 131 132 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "台帳に書かない" ledger_lines 0
check "ログに理由" grep -qF 'pid=131: cwd が分からない' "$LOG"

reset "sessions/<pid>.json を読めないものは候補にしない"
proc 101 claude /w/a "" -
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "台帳に書かない" ledger_lines 0

# ---- stop: 裏で動くもの (止めると resume で戻らない) ----
reset "stop-bg-shell: 子孫にシェルが居れば送らない"
proc 101 claude /w/a "" SID-1
child 300 101 node
child 301 300 zsh
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "ログに bg-shell" grep -qF 'pid=101: bg-shell' "$LOG"

reset "stop-login-shell-name: ログインシェルの名前 (-/bin/zsh) も数える"
proc 101 claude /w/a "" SID-1
child 300 101 -/bin/zsh
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "ログに bg-shell" grep -qF 'pid=101: bg-shell' "$LOG"

reset "stop-shell-elsewhere: 対象の子孫でないシェルは数えない"
child 500 1 -/bin/zsh # 対象のタブのシェル (親)
proc 101 claude /w/a "" SID-1
echo 500 >"$FAKE/procs/101/ppid"
child 501 1 zsh
child 502 501 bash
proc 102 claude /w/b "" SID-2 # 別のセッションの子のシェル
child 503 102 zsh
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送る" sent 101
check "別のセッションには送らない" not_sent 102

reset "stop-mcp-children: 子孫がシェルでない (空白入りの名前も) なら送る"
proc 101 claude /w/a "" SID-1
child 300 101 node
child 301 300 "npm exec sh"
child 302 101 /opt/x/bin/zshrc-lint
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送る" sent 101

reset "stop-prompt-checked-last: 入力欄は送る直前に見る"
proc 101 claude /w/a "" SID-1
cat >"$FAKE/procs/101/on_ww" <<'EOF'
echo '["❯ あとでこれを", "────"]' >"$FAKE/procs/101/tail"
EOF
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "ログに input not empty" grep -qF 'pid=101: input not empty' "$LOG"

reset "stop-status-changed-last: 記録は送る直前に読み直す"
proc 101 claude /w/a "" SID-1
cat >"$FAKE/procs/101/on_ww" <<'EOF'
f="$CLAUDE_CONFIG_DIR/sessions/101.json"
jq '.status = "busy"' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
EOF
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "ログに changed before send" grep -qF 'pid=101: changed before send' "$LOG"

reset "ledger-lost-note: Claude の行にだけ戻らないものを書く"
proc 101 claude /w/a "" SID-1
proc 201 codex /w/c ""
bash "$script" stop 101 201 >/dev/null 2>&1
check "台帳に 2 行" ledger_lines 2
check "claude の行に /loop" grep -qF '/loop' <<<"$(awk -F'\t' '$3 == "claude /w/a" { print $6 }' "$ledger")"
check "codex の行は空" [ -z "$(awk -F'\t' '$3 == "codex /w/c" { print $6 }' "$ledger")" ]

# 会話記録の形は実物に合わせる (tool_use は .message.content[] の要素)。
reset "stop-scheduled: 予約を作る呼び出しが在るセッションは送らない"
proc 101 claude /w/a "" SID-1
tx SID-1 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"予約します"},{"type":"tool_use","id":"t1","name":"CronCreate","input":{"cron":"*/5 * * * *"}}]}}'
proc 102 claude /w/b "" SID-2
tx SID-2 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"ScheduleWakeup","input":{}}]}}'
listed=$(bash "$script" list 2>/dev/null)
check "list の残すものに CronCreate の分" grep -qF "$(printf '101\tclaude\t100h\tscheduled')" <<<"$listed"
check "list の残すものに ScheduleWakeup の分" grep -qF "$(printf '102\tclaude\t100h\tscheduled')" <<<"$listed"
bash "$script" stop 101 102 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "ログに scheduled (CronCreate)" grep -qF 'pid=101: scheduled' "$LOG"
check "ログに scheduled (ScheduleWakeup)" grep -qF 'pid=102: scheduled' "$LOG"

reset "stop-scheduled-mention: 道具の一覧や本文の名前だけなら送る"
proc 101 claude /w/a "" SID-1
tx SID-1 '{"type":"system","shape":{"tools":[{"name":"CronCreate","description":"Schedule a prompt"},{"name":"ScheduleWakeup","description":"/loop"}]}}'
tx SID-1 '{"type":"attachment","attachment":{"addedNames":["CronCreate","ScheduleWakeup"]}}'
tx SID-1 '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"CronCreate は使わない"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo ScheduleWakeup"}}]}}'
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送る" sent 101

reset "stop-sched-unknown: 会話記録が無ければ送らない"
proc 101 claude /w/a "" SID-1
rm -f "$CLAUDE_CONFIG_DIR/projects/x/SID-1.jsonl"
bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "ログに sched-unknown" grep -qF 'pid=101: sched-unknown' "$LOG"
bash "$script" scan >/dev/null 2>&1
check "scan のログに sched_unknown=1" grep -qE '^[^ ]+ [^ ]+ scan .* sched_unknown=1( |$)' "$LOG"

# 時刻を除いたログと通知が同じであること。2 回目は鍵が知らせ済みにならないよう、状態を消してから流す。
scan_out() { # scan_out <scan の引数...>: reset 済みの状態で 1 本置いて scan を流し、ログ (時刻を除く) と通知を出す
    proc 101 claude /w/a "" SID-1
    bash "$script" scan "$@" >/dev/null 2>&1
    sed 's/^[^ ]* [^ ]* //' "$LOG"
    echo "--"
    cat "$FAKE/notified" 2>/dev/null
}
reset "scan-auto-ignored: scan --auto は scan と同じ"
plain=$(scan_out)
reset "scan-auto-ignored: scan --auto は scan と同じ"
auto=$(scan_out --auto)
check "候補を知らせる" grep -qF '止める候補 1 本' <<<"$plain"
check "ログと通知が同じ" same "$auto" "$plain"

# ---- stop: 「触らない」リスト ----
reset "リストが無い回は 1 本も止めない"
proc 101 claude /w/a "" SID-1
proc 201 codex /w/c ""
rm -f "$CLEANUP_KEEP"
bash "$script" stop 101 201 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "台帳に書かない" ledger_lines 0
check "ログに理由" grep -qF "$CLEANUP_KEEP" "$LOG"
check "通知を 1 回" [ "$(grep -c . "$FAKE/notified" 2>/dev/null)" = 1 ]
bash "$script" stop 101 201 >/dev/null 2>&1
check "同じ日の 2 回目は通知しない" [ "$(grep -c . "$FAKE/notified" 2>/dev/null)" = 1 ]
check "2 回目も送らない" sent_none
check "worktree-gc の印は使わない" [ ! -e "$STATE_ROOT/worktree-gc/keep-missing-warned" ]

reset "リストに当たる cwd は止めない"
proc 101 claude /a/pr-12 "" SID-1
proc 201 codex /a/pr-12/sub ""
proc 102 claude /a/pr-123 "" SID-2
echo /a/pr-12 >"$CLEANUP_KEEP"
bash "$script" stop 101 201 102 >/dev/null 2>&1
check "当たるものは送らない" not_sent 101
check "中のパスも送らない" not_sent 201
check "/a/pr-12 は /a/pr-123 を守らない" sent 102
check "台帳は止めたものだけ" ledger_lines 1

# agent-gc はセッションを止めるだけで中身は消さないので、行が cwd の中を指すとき (祖先の一致) は守らない。
reset "cwd が行そのものか行の下のときだけ守る"
proc 141 claude /a/b "" SID-A1
proc 142 claude /a/b/c/d "" SID-A2
echo /a/b/c >"$CLEANUP_KEEP"
bash "$script" stop 141 142 >/dev/null 2>&1
check "行の上の cwd は止める" sent 141
check "行の下の cwd は止めない" not_sent 142

reset "「無い」と「読めない行が在る」は別々に 1 日 1 回知らせる"
proc 101 claude /w/a "" SID-1
rm -f "$CLEANUP_KEEP"
bash "$script" stop 101 >/dev/null 2>&1
check "無い回に 1 本" [ "$(grep -c . "$FAKE/notified" 2>/dev/null)" = 1 ]
printf '%s\n' '$HOME/x' >"$CLEANUP_KEEP"
bash "$script" stop 101 >/dev/null 2>&1
check "同じ日でも、読めない行の回にもう 1 本" [ "$(grep -c . "$FAKE/notified" 2>/dev/null)" = 2 ]
check "2 本目は読めない行の知らせ" [ -n "$(sed -n 2p "$FAKE/notified" | grep -F '読めない行')" ]
bash "$script" stop 101 >/dev/null 2>&1
check "読めない行の 2 回目は出ない" [ "$(grep -c . "$FAKE/notified" 2>/dev/null)" = 2 ]
check "どの回も送らない" sent_none

reset "リストが無い回の DRY_RUN は、通知も印も出さない"
proc 101 claude /w/a "" SID-1
rm -f "$CLEANUP_KEEP"
DRY_RUN=1 bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none
check "通知しない" [ ! -s "$FAKE/notified" ]
check "印を書かない" [ ! -e "$STATE_ROOT/agent-gc/keep-missing-warned" ]

reset "EXCLUDE_RE はリストが空でも今どおり"
proc 101 claude /w/skip/x "" SID-1
EXCLUDE_RE='^/w/skip' bash "$script" stop 101 >/dev/null 2>&1
check "/exit を送らない" sent_none

# ---- symlink 経由の起動 ----
# ~/.local/bin/agent-gc は、nix の store を挟んだ symlink の連なりでリポのスクリプトを指す。相対のリンクも混ぜる。
reset "symlink 経由でも共有ファイルを読める"
mkdir -p "$base/links/bin" "$base/links/store"
ln -s "$script" "$base/links/store/agent-gc.sh"
ln -s ../store/agent-gc.sh "$base/links/bin/agent-gc"
proc 101 claude /w/a "" SID-1
bash "$base/links/bin/agent-gc" stop 101 >/dev/null 2>&1
check "/exit を送る" sent 101
check "台帳に 1 行" ledger_lines 1

reset "共有ファイルを読めなければ 1 本も止めない"
mkdir -p "$base/alone"
cp "$script" "$base/alone/agent-gc.sh"
proc 201 codex /w/c ""
bash "$base/alone/agent-gc.sh" stop 201 >/dev/null 2>&1
check "/exit を送らない" sent_none
# 「リストが無い」の経路でも送らないので、止めた理由をログの文面で見分ける。
check "ログに理由" grep -qF 'cleanup-ledger.sh を読めない' "$LOG"
check "judge は今どおり" [ "$(jq -c . <<<"$base_row" | bash "$base/alone/agent-gc.sh" judge | jq -r '.reason // "null"')" = null ]

[ "$fail" = 0 ] && echo "ok"
exit "$fail"
