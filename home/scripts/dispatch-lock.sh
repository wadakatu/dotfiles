#!/usr/bin/env bash
#
# pr-dispatch.sh と agent-resume.sh が source する共有ロック。
#   dispatch_lock || exit 0
#
# 2 つは別々の LaunchAgent から呼ばれ、互いを知らない。同じ worktree に、片方がセッションの再開を、
# もう片方が PR 対応のエージェントを同時に起動しないよう、実行の全体を 1 つずつにする。
# 取れなければ、その回は何もしない (launchd が数分後にまた呼ぶ)。
# 呼び出し側で log を定義しておく。
DISPATCH_LOCK="${DISPATCH_LOCK:-$HOME/Library/Application Support/pr-dispatch/lock.d}"
# 相手が終わるのを待つ秒数。2 つの LaunchAgent は同じ間隔で同時に起きるので、待たないと毎回同じ側が負ける。
DISPATCH_LOCK_WAIT="${DISPATCH_LOCK_WAIT:-60}"

# ロックの持ち主がまだ動いているか。pid は別のプロセスに使い回されうるので、コマンドの名前も見る。
dispatch_lock_owner_alive() {
    ps -o command= -p "$1" 2>/dev/null | grep -Eq 'pr-dispatch\.sh|agent-resume\.sh'
}

dispatch_lock() {
    local i=0 p
    mkdir -p "${DISPATCH_LOCK%/*}"
    while ! mkdir "$DISPATCH_LOCK" 2>/dev/null; do
        p=$(cat "$DISPATCH_LOCK/pid" 2>/dev/null || true)
        # 持ち主が死んでいるロックは回収する。pid を書く前に死んだもの (pid が無いまま 1 分以上) も同じ。
        # 回収も 1 プロセスだけ。取ったあとで pid を読み直し、別の持ち主に替わっていれば消さない。
        # ponytail: 回収の途中で落ちると lock.d.reclaim が残る。そのときは手で消す (ログの「ロックが空かない」で気づく)
        if { if [ -n "$p" ]; then ! dispatch_lock_owner_alive "$p"; else [ -n "$(find "$DISPATCH_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; fi; } &&
            mkdir "$DISPATCH_LOCK.reclaim" 2>/dev/null; then
            if [ "$(cat "$DISPATCH_LOCK/pid" 2>/dev/null || true)" = "$p" ]; then
                log "死んだロックを回収 (pid ${p:-なし})"
                rm -rf "$DISPATCH_LOCK"
            fi
            rmdir "$DISPATCH_LOCK.reclaim"
            continue
        fi
        if [ "$i" -ge "$DISPATCH_LOCK_WAIT" ]; then
            log "ロックが空かない (pid ${p:-?})。この回は見送り"
            return 1
        fi
        i=$((i + 1))
        sleep 1
    done
    echo $$ >"$DISPATCH_LOCK/pid"
    trap 'rm -rf "$DISPATCH_LOCK"' EXIT
}
