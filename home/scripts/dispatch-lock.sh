#!/usr/bin/env bash
#
# pr-dispatch.sh と agent-resume.sh が source する共有ロック。
#   dispatch_lock || exit 0
#
# 2 つは別々の LaunchAgent から呼ばれ、互いを知らない。同じ worktree に、片方がセッションの再開を、
# もう片方が PR 対応のエージェントを同時に起動しないよう、実行の全体を 1 つずつにする。
# 取れなければ、その回は何もしない (launchd が数分後にまた呼ぶ)。
# 呼び出し側で log を定義しておく。
#
# ロックは「持ち主の pid を指す symlink」。symlink は作ると同時に中身 (pid) が入るので、
# 「ロックはあるが持ち主がまだ書かれていない」瞬間が無い (ディレクトリ + pid ファイルだと、その瞬間に
# 別のプロセスが「持ち主の無い古いロック」と見て消せてしまう)。
DISPATCH_LOCK="${DISPATCH_LOCK:-$HOME/Library/Application Support/pr-dispatch/lock}"
# 相手が終わるのを待つ秒数。2 つの LaunchAgent は同じ間隔で同時に起きるので、待たないと毎回同じ側が負ける。
DISPATCH_LOCK_WAIT="${DISPATCH_LOCK_WAIT:-60}"

# ロックの持ち主がまだ動いているか。pid は別のプロセスに使い回されうるので、コマンドの名前も見る。
dispatch_lock_owner_alive() {
    ps -o command= -p "$1" 2>/dev/null | grep -Eq 'pr-dispatch\.sh|agent-resume\.sh'
}

dispatch_lock() {
    local i=0 p
    mkdir -p "${DISPATCH_LOCK%/*}"
    # -n: 既にある symlink をたどらない (たどると、指す先がディレクトリのときにその中へ作って成功してしまう)。
    while ! ln -sn "$$" "$DISPATCH_LOCK" 2>/dev/null; do
        p=$(readlink "$DISPATCH_LOCK" 2>/dev/null || true)
        # 持ち主が死んでいるロックは回収する。回収も 1 プロセスだけ。
        # 取ったあとで持ち主を読み直し、別の持ち主に替わっていれば消さない。
        # ponytail: 回収の途中で落ちると lock.reclaim が残る。そのときは手で消す (ログの「ロックが空かない」で気づく)
        if [ -n "$p" ] && ! dispatch_lock_owner_alive "$p" && mkdir "$DISPATCH_LOCK.reclaim" 2>/dev/null; then
            if [ "$(readlink "$DISPATCH_LOCK" 2>/dev/null || true)" = "$p" ]; then
                log "死んだロックを回収 (pid $p)"
                rm -f "$DISPATCH_LOCK"
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
    # 自分のロックだけを消す (誤って回収され、別の持ち主に替わっていたら触らない)。
    trap '[ "$(readlink "$DISPATCH_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$DISPATCH_LOCK"' EXIT
}
