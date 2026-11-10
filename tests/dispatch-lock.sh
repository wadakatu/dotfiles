#!/usr/bin/env bash
# home/scripts/dispatch-lock.sh と、それを使う pr-dispatch.sh / agent-resume.sh の排他を確かめる。
# CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/dispatch-lock.sh
# orca / gh / claude / sysctl は偽物。2 つのスクリプトが同時に動かないことと、
# 止まった実行の残したロックで以後の実行が止まり続けないことを主に見る。
set -u
# shellcheck disable=SC2016  # '...' の中の $x は偽コマンドの変数

root=$(cd "$(dirname "$0")/.." && pwd)
lib="$root/home/scripts/dispatch-lock.sh"
dispatch="$root/home/scripts/pr-dispatch.sh"
resume="$root/home/scripts/agent-resume.sh"
base=$(mktemp -d)
base=$(cd "$base" && pwd -P)
bg=""
trap '[ -n "$bg" ] && kill $bg 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
CASE=""
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}

# ---- 偽のコマンド ----
mkdir -p "$base/bin"
# 呼ばれたことを "<誰が> <引数>" で記録する。status は FAKE_ORCA_SLEEP 秒待ってから返す (ロックを持ったまま止まる実行を作る)。
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo "${WHO:-?} orca $*" >>"$FAKE/calls"
case "$1 $2" in
    "status --json") sleep "${FAKE_ORCA_SLEEP:-0}"; echo '{"result":{"runtime":{"reachable":true}}}' ;;
    *) echo '{"ok":true,"result":{"worktrees":[]}}' ;;
esac
EOF
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "${WHO:-?} gh $*" >>"$FAKE/calls"
echo me
EOF
cat >"$base/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "${WHO:-?} claude $*" >>"$FAKE/calls"
EOF
# agent-resume.sh は起動 ID を sysctl から読む (macOS だけにあるキー)。
cat >"$base/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *kern.bootsessionuuid*) echo BOOT-NOW ;;
    *kern.boottime*) echo '{ sec = 1700000000, usec = 0 } Tue Nov 14 22:13:20 2023' ;;
esac
EOF
chmod +x "$base/bin"/*
export PATH="$base/bin:$PATH"
# 本物の orca や gh に届くと、手元のエージェントを起動してしまう。偽物が先に効いていなければ止める。
for c in orca gh claude sysctl; do
    [ "$(command -v "$c")" = "$base/bin/$c" ] || { echo "偽の $c が効いていない。中止"; exit 1; }
done

export FAKE="$base/fake"
export DISPATCH_LOCK="$base/state/lock" DISPATCH_LOCK_WAIT=0
export STATE_DIR="$base/state/agent-resume" STATE_FILE="$base/state/dispatched.tsv" BOARD_FILE="$base/state/board.tsv"
export ORCA_ROOT="$base/workspaces" LAUNCH_INTERVAL=0
mkdir -p "$FAKE" "$base/state" "$ORCA_ROOT"

reset() { # 記録とロックを消す
    # wait で回収しておく (しないと、bash が「Terminated」をテストの出力に混ぜる)。
    # shellcheck disable=SC2086  # $bg は pid の並び
    [ -n "$bg" ] && { kill $bg; wait $bg; } 2>/dev/null
    bg=""
    rm -rf "$DISPATCH_LOCK" "$DISPATCH_LOCK.reclaim" "$STATE_DIR"
    : >"$FAKE/calls"
}
called() { grep -qF -- "$1" "$FAKE/calls"; }
not_called() { ! grep -qF -- "$1" "$FAKE/calls"; }
# ロックは持ち主の pid を指す symlink。
unlocked() { [ ! -L "$DISPATCH_LOCK" ] && [ ! -e "$DISPATCH_LOCK" ]; }
owner() { [ "$(readlink "$DISPATCH_LOCK" 2>/dev/null)" = "$1" ]; }

# ロックを持って動いている実行のふりをする。持ち主の判定はコマンドの名前も見るので、同じ名前のスクリプトを動かす。
mkdir -p "$base/holder"
printf '#!/usr/bin/env bash\nsleep "${1:-30}"\n' >"$base/holder/pr-dispatch.sh"
hold() { # hold [秒]: 生きている持ち主がロックを持っている状態にする
    bash "$base/holder/pr-dispatch.sh" "${1:-30}" &
    bg="$bg $!"
    holder=$!
    ln -sn "$holder" "$DISPATCH_LOCK"
}
# ロックを取って、取れたら自分の pid と "got" を書いて抜ける。log の出力は $base/lib.log へ。
try_lock() {
    bash -c 'log() { echo "$*"; }; . "$1"; dispatch_lock && { echo got; readlink "$DISPATCH_LOCK"; echo $$; }' \
        pr-dispatch.sh "$lib" >"$base/lib.log" 2>&1
}
got() { grep -qx got "$base/lib.log"; }

# ---- ロックの単体 ----
CASE="空いている"
reset
try_lock
check "取れる" got
check "自分の pid を書く" [ "$(sed -n 2p "$base/lib.log")" = "$(sed -n 3p "$base/lib.log")" ]
check "抜けたら離す" unlocked

CASE="生きている持ち主が居る"
reset
hold
try_lock
check "取れない" [ $? -ne 0 ]
check "見送りをログに出す" grep -q "見送り" "$base/lib.log"
check "持ち主のロックは残る" owner "$holder"

CASE="持ち主が死んでいる"
reset
bash -c 'exit 0' &
dead=$!
wait "$dead"
ln -sn "$dead" "$DISPATCH_LOCK"
try_lock
check "回収して取れる" got
check "回収をログに出す" grep -q "回収" "$base/lib.log"
check "抜けたら離す" unlocked

CASE="持ち主の pid が別のプロセスに使い回された"
reset
sleep 30 &
bg="$bg $!"
ln -sn "$!" "$DISPATCH_LOCK"
try_lock
check "回収して取れる" got

CASE="回収しようとした間に、別の実行が回収して取り直した"
# 死んだ持ち主を読んだ後で、別の実行が先に回収して自分のロックを作った。その新しいロックを消してはいけない。
# 「持ち主が生きているか」を見る瞬間に割り込みを起こす。
reset
bash -c 'exit 0' &
dead=$!
wait "$dead"
ln -sn "$dead" "$DISPATCH_LOCK"
bash "$base/holder/pr-dispatch.sh" 30 &
bg="$bg $!"
winner=$!
SWAP_DONE="$base/swap-done" NEW_OWNER="$winner" bash -c '
    log() { echo "$*"; }
    . "$1"
    eval "real_$(declare -f dispatch_lock_owner_alive)"
    dispatch_lock_owner_alive() {
        if [ ! -e "$SWAP_DONE" ]; then
            : >"$SWAP_DONE"
            rm -f "$DISPATCH_LOCK"
            ln -sn "$NEW_OWNER" "$DISPATCH_LOCK"
            return 1
        fi
        real_dispatch_lock_owner_alive "$@"
    }
    dispatch_lock && echo got' pr-dispatch.sh "$lib" >"$base/lib.log" 2>&1
check "割り込みが起きた (テストの前提)" [ -e "$base/swap-done" ]
check "取れない" [ -z "$(grep -x got "$base/lib.log")" ]
check "取り直した側のロックは残る" owner "$winner"
rm -f "$base/swap-done"

CASE="別の実行が回収している最中"
# 回収は 1 つずつ。回収中の印があれば、死んだロックでも手を出さない
# (回収の途中で落ちて印が残ると止まり続ける。そのときは手で消す、とスクリプトに書いてある)。
reset
bash -c 'exit 0' &
dead=$!
wait "$dead"
ln -sn "$dead" "$DISPATCH_LOCK"
mkdir "$DISPATCH_LOCK.reclaim"
try_lock
check "取れない" [ $? -ne 0 ]
check "ロックに触らない" owner "$dead"
check "止まっている理由をログに出す" grep -q "ロックが空かない" "$base/lib.log"

CASE="持っている間に、別の持ち主に替わった"
# 誤って回収されたときの保険。抜けるときに、自分のものでないロックを消さない。
reset
bash -c 'log() { echo "$*"; }; . "$1"; dispatch_lock && rm -f "$DISPATCH_LOCK" && ln -sn 999999 "$DISPATCH_LOCK"' \
    pr-dispatch.sh "$lib" >"$base/lib.log" 2>&1
check "別の持ち主のロックは残す" owner 999999

CASE="死んだロックを 8 つが同時に取りに行く"
# 回収と取得が重なっても、同時に入るのは 1 つだけ。
reset
bash -c 'exit 0' &
dead=$!
wait "$dead"
ln -sn "$dead" "$DISPATCH_LOCK"
: >"$base/crit"
pids=""
for _ in 1 2 3 4 5 6 7 8; do
    DISPATCH_LOCK_WAIT=30 bash -c 'log() { :; }; . "$1"; dispatch_lock || exit 1
        echo "in $$" >>"$2"; sleep 0.2; echo "out $$" >>"$2"' pr-dispatch.sh "$lib" "$base/crit" &
    pids="$pids $!"
done
# shellcheck disable=SC2086  # $pids は pid の並び
wait $pids
check "8 つとも入った" [ "$(grep -c '^in ' "$base/crit")" = 8 ]
# in と out が同じ pid で交互に並ぶ = 重なっていない。
check "重ならない" awk '$1 == "in" { if (cur != "") exit 1; cur = $2 } $1 == "out" { if (cur != $2) exit 1; cur = "" } END { exit cur != "" }' "$base/crit"
check "最後は離す" unlocked

CASE="持ち主が終わるのを待つ"
reset
hold 2
( sleep 2; rm -f "$DISPATCH_LOCK" ) & # 持ち主は終わるときにロックを消す
bg="$bg $!"
DISPATCH_LOCK_WAIT=10 try_lock
check "待って取れる" got

# ---- スクリプト ----
mark() { # 前の起動の印を 1 つ置く (agent-resume が再開する対象)
    mkdir -p "$STATE_DIR/sessions" "$base/wt"
    printf 'BOOT-OLD\t1\trepo::%s\t%s\t%s\n' "$base/wt" "$base/wt" "$base/none.jsonl" >"$STATE_DIR/sessions/sid-1"
}

CASE="agent-resume: ロックが取れない"
reset
mark
hold
WHO=resume bash "$resume" >"$base/out" 2>&1
check "exit 0" [ $? -eq 0 ]
check "orca を呼ばない" not_called "resume orca"
check "印を動かさない" [ -f "$STATE_DIR/sessions/sid-1" ]
check "持ち主のロックは残る" owner "$holder"

CASE="agent-resume: ロックが空いている"
reset
mark
WHO=resume bash "$resume" >"$base/out" 2>&1
check "exit 0" [ $? -eq 0 ]
check "再開のタブを作る" called "resume orca terminal create --worktree id:repo::$base/wt"
check "抜けたら離す" unlocked

CASE="agent-resume: DRY_RUN はロックを取らない"
reset
mark
hold
WHO=resume DRY_RUN=1 bash "$resume" >"$base/out" 2>&1
check "ロックがあっても動く" grep -q "DRY-RUN: resume sid-1" "$base/out"
check "タブは作らない" not_called "terminal create"
check "持ち主のロックは残る" owner "$holder"

CASE="agent-resume launch: ロックを取らない"
# Orca のタブの中で動く再開の本体。ここで待つと、ロックを持った実行が終わるまでセッションが始まらない。
reset
hold
WHO=launch bash "$resume" launch sid-1 idle "$base/wt" >"$base/out" 2>&1
check "claude を起動する" called "launch claude -r sid-1"
check "持ち主のロックは残る" owner "$holder"

CASE="pr-dispatch: ロックが取れない"
reset
hold
WHO=dispatch bash "$dispatch" >"$base/out" 2>&1
check "exit 0" [ $? -eq 0 ]
check "orca を呼ばない" not_called "dispatch orca"
check "gh を呼ばない" not_called "dispatch gh"
check "持ち主のロックは残る" owner "$holder"

CASE="pr-dispatch: ロックが空いている"
reset
WHO=dispatch bash "$dispatch" >"$base/out" 2>&1
check "exit 0" [ $? -eq 0 ]
check "Orca を見に行く" called "dispatch orca status --json"
check "抜けたら離す" unlocked

CASE="pr-dispatch: DRY_RUN はロックを取らない"
reset
hold
WHO=dispatch DRY_RUN=1 bash "$dispatch" >"$base/out" 2>&1
check "ロックがあっても動く" called "dispatch orca status --json"
check "持ち主のロックは残る" owner "$holder"

CASE="pr-dispatch の実行中に agent-resume が来る"
reset
mark
WHO=dispatch FAKE_ORCA_SLEEP=3 bash "$dispatch" >"$base/out-dispatch" 2>&1 &
dpid=$!
bg="$bg $dpid"
for _ in 1 2 3 4 5 6 7 8 9 10; do owner "$dpid" && break; sleep 0.2; done
check "pr-dispatch がロックを持つ (テストの前提)" owner "$dpid"
WHO=resume bash "$resume" >"$base/out" 2>&1
check "待たない設定なら見送る" not_called "resume orca"
WHO=resume DISPATCH_LOCK_WAIT=20 bash "$resume" >"$base/out" 2>&1
check "待てば、終わった後に動く" called "resume orca terminal create"
# pr-dispatch の最後の呼び出しより後に、agent-resume の最初の呼び出しが来る。
check "重ならない" [ "$(grep -n '^dispatch ' "$FAKE/calls" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^resume ' "$FAKE/calls" | head -1 | cut -d: -f1)" ]
wait "$dpid" 2>/dev/null
check "どちらも離す" unlocked

[ "$fail" = 0 ] && echo "dispatch-lock: all checks passed"
exit "$fail"
