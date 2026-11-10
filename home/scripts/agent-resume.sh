#!/usr/bin/env bash
#
# Mac の再起動で止まった Claude のセッションを、Orca のタブで再開する。
# Orca は再起動でエージェントのプロセスを失い、タブの配置とスクロールバックしか戻さない
# (Orca docs `model/session-restore.mdx` の "What doesn't get restored")。
#
# 印は SessionStart hook (agents/claude/hooks/session-marker.sh) がセッションごとに置く。
#   今回の起動より前の印 → 止まる直前まで生きていたセッションなので、再開する
#   今回の起動の印で、claude のプロセスが無いもの → 普通に終わったセッションなので、印を消す
# 再開のしかたは会話記録の末尾で決める。
#   AskUserQuestion の答え待ち → 同じ質問を出し直させる
#   作業の途中 → 状況を確かめて続けさせる
#   手が空いていた → 会話を開くだけ (指示を送らないので、トークンを使わない)
#
# あわせて、Needs decision のカードで会話が開いていない (ターミナルが 1 つも無い) worktree は、
# 最後の対話セッションを開き直し、判断待ちがまだ残っているかを確かめさせる (下の「Needs decision」の節)。
# pr-dispatch.sh が、毎回の最初に呼ぶ (ログイン時と 3 分ごと)。
#
# 手で確認するとき:
#   DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/agent-resume.sh
#
set -euo pipefail

# Orca のタブの中で実行される再開の本体。PATH はタブのシェルのものを使う (claude は ~/.local/bin)。
if [ "${1:-}" = "launch" ]; then
    sid="$2" kind="$3" cwd="$4"
    cd "$cwd"
    case "$kind" in
    question)
        exec claude -r "$sid" "Mac の再起動でセッションが止まり、直前の AskUserQuestion の答えを受け取れていません。同じ質問を AskUserQuestion でもう一度出してください。"
        ;;
    work)
        exec claude -r "$sid" "Mac の再起動でセッションが途中で止まりました。git status と直前の会話から状況を確かめて、中断した作業を続けてください。もう終わっていたら、何もせずにそう伝えてください。"
        ;;
    recheck)
        exec claude -r "$sid" "Orca のボードでこのカードは Needs decision にありますが、会話が開いていなかったので開き直しました。直前の会話と git・PR の状態から、ユーザーの判断待ちがまだ残っているかを確かめてください。残っているなら、同じ判断を AskUserQuestion でもう一度聞き、\`orca worktree set --worktree current --unread --json\` で未読にしてください（列は Needs decision のまま）。もう要らなくなっていたら、\`orca worktree set --worktree current --workspace-status <in-progress / in-review / completed のどれか> --comment \"<今の状態を 1 行>\" --json\` で列を直して止まってください。新しい作業は始めないでください。"
        ;;
    *)
        exec claude -r "$sid"
        ;;
    esac
fi

# launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin だけで、orca も jq も入らない。
# 後ろに足す (worktree-gc.sh と同じ)。テストが偽の orca を先に効かせられるようにするため。
PATH="$PATH:/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=en_US.UTF-8

# 状態の置き場所。テストは STATE_ROOT を一時ディレクトリに向ける (dispatch-lock.sh のコメントを参照)。
STATE_ROOT="${STATE_ROOT:-$HOME/Library/Application Support}"
STATE_DIR="$STATE_ROOT/agent-resume"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
# 再開の間隔。ログイン直後に claude を一斉に立ち上げて、Orca のターミナル起動の制限に掛からないため。
LAUNCH_INTERVAL="${LAUNCH_INTERVAL:-5}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# pr-dispatch.sh と同時には動かない。再開を依頼している間に、同じ worktree へ PR 対応のエージェントを
# 起動させないため。普段は pr-dispatch.sh が、自分のロックを持ったまま毎回の最初に呼ぶ (DISPATCH_LOCK_HELD=1)。
# 手で動かしたときは自分で取る。DRY_RUN は何も起動しないので、取らない。
# shellcheck source=home/scripts/dispatch-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/dispatch-lock.sh"
if [ "$DRY_RUN" != "1" ] && [ "${DISPATCH_LOCK_HELD:-0}" != "1" ]; then
    dispatch_lock || exit 0
fi

# 指示を渡して再開したタブの記録。1 行が <handle> <paneKey> <worktreeId> <sid> <時刻> (タブ区切り)。
# pr-dispatch.sh が、そのタブに指示が入るまで同じ worktree への起動を待つために読み、指示が入ったら行を消す。
# 手が空いていたセッションは会話を開くだけで自分からは動かないので、書かない。
PENDING_FILE="$STATE_DIR/resume-pending.tsv"

# open_tab <worktreeId> <sid> <kind> <cwd>: 再開のタブを作る。作れたら 0。
# タブを作る前に handle の無い行 (- -) を書き、作れたら handle と paneKey を補う。作った直後に落ちても、
# 再開を依頼したかもしれないという記録が残る。Orca が失敗を返したときだけ行を消す。返事が読めないときは残す。
open_tab() {
    local wtid=$1 sid=$2 kind=$3 cwd=$4 now out rc=0 handle pane
    now=$(date +%s)
    if [ "$kind" != "idle" ]; then
        # 同じセッションの handle の無い行は 1 つまで (失敗して次の回に試し直しても増えない)。
        # 記録を書けなければ、タブを作らない (再開を依頼したのに記録が無い、を作らないため)。
        # この関数は if の条件として呼ばれ、中では set -e が効かないので、失敗は自分で見る。
        if ! { pending_fill "$wtid" "$sid" "" "" "" &&
            printf -- '-\t-\t%s\t%s\t%s\n' "$wtid" "$sid" "$now" >>"$PENDING_FILE"; } 2>/dev/null; then
            log "再開の記録を書けない ($PENDING_FILE)。タブは作らない"
            return 1
        fi
    fi
    out=$(orca terminal create --worktree "id:$wtid" --title "再開" \
        --command "bash '${BASH_SOURCE[0]}' launch '$sid' '$kind' '$cwd'" --json 2>/dev/null) || rc=$?
    [ "$kind" != "idle" ] || return "$rc"
    handle=$(jq -r '.result.terminal.handle // empty' <<<"$out" 2>/dev/null || true)
    pane=$(jq -r '.result.terminal.paneKey // empty' <<<"$out" 2>/dev/null || true)
    if [ "$rc" = 0 ] && [ -n "$handle" ]; then
        pending_fill "$wtid" "$sid" "$now" "$handle" "${pane:--}"
    elif [ "$(jq -r '.ok' <<<"$out" 2>/dev/null || true)" = "false" ]; then
        pending_fill "$wtid" "$sid" "$now" "" ""
    fi
    return "$rc"
}

# pending_fill <worktreeId> <sid> <時刻> <handle> <paneKey>: handle の無い行に handle と paneKey を補う。
# handle が空なら、その行を消す (時刻も空なら、そのセッションの handle の無い行を全部消す)。
pending_fill() {
    touch "$PENDING_FILE" &&
        awk -F'\t' -v OFS='\t' -v w="$1" -v s="$2" -v t="$3" -v h="$4" -v p="$5" '
            $1 == "-" && $3 == w && $4 == s && (t == "" || $5 == t) { if (h == "") next; $1 = h; $2 = p }
            { print }' "$PENDING_FILE" >"$PENDING_FILE.tmp" &&
        mv "$PENDING_FILE.tmp" "$PENDING_FILE"
}

# 会話記録の末尾から、止まったときの状態を question / work / idle で返す。
classify() {
    [ -f "$1" ] || { echo idle; return; }
    tail -n 200 "$1" | jq -rs '
        [.[] | select((.type == "user" or .type == "assistant") and (.isMeta | not))] | last // {}
        | (.message.content // "") as $c
        | ([$c | arrays | .[] | select(type == "object")]) as $blocks
        | ($c | if type == "string" then . else ([$blocks[] | select(.type == "text") | .text] | join("")) end) as $text
        | if .type == "assistant" then
            ([$blocks[] | select(.type == "tool_use") | .name]) as $tools
            | if ($tools | index("AskUserQuestion")) then "question"
              elif ($tools | length) > 0 then "work"
              else "idle" end
          elif .type == "user" then
            if ($text | test("^(<command-|<local-command|\\[Request interrupted)")) then "idle" else "work" end
          else "idle" end' 2>/dev/null || echo idle
}

# Orca に繋がらない間は何もしない。再起動の直前に Orca が先に落ちると claude のプロセスも全部消えていて、
# ここで印を消すと再開の手がかりが無くなる。ログイン直後は、Orca が立ち上がるまで次の回に回す。
orca worktree ps --json >/dev/null 2>&1 || exit 0

# 起動ごとに変わる ID。session-marker.sh と同じ値にする。
# 以前は kern.boottime の秒を使っていたが、再起動していないのに時計の補正で 2 秒ずれ、
# 生きている 6 つのセッションを「前の起動」と取り違えて二重に開いた (2026-10-26 12:07)。
boot=$(sysctl -n kern.bootsessionuuid)
# 以前の形式の印 (kern.boottime の秒) が今の起動のものかを見分けるため。時計の補正による数秒のずれは許す。
boot_sec=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
mkdir -p "$STATE_DIR/sessions" "$STATE_DIR/resumed"
# この回で再開した worktree。下の Needs decision の節で二重に開かないため。
launched=""

for f in "$STATE_DIR/sessions"/*; do
    [ -f "$f" ] || continue
    sid=${f##*/}
    IFS=$'\t' read -r b pid wtid cwd transcript <"$f" || continue

    # 以前の形式の印は、起動時刻の差が 5 分以内なら今の起動のものとして、今の起動 ID に書き換える。
    # それより離れていれば前の起動のものなので、そのまま下の再開に回す。
    if [[ "$b" =~ ^[0-9]+$ ]] && [ "$(( b > boot_sec ? b - boot_sec : boot_sec - b ))" -le 300 ]; then
        b=$boot
        [ "$DRY_RUN" = "1" ] || printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$pid" "$wtid" "$cwd" "$transcript" >"$f"
    fi

    # 今の起動の印は、claude のプロセスが生きていれば何もせず、無ければ普通に終わったので消す。
    # 起動 ID が違う印は前の起動のもの。pid は再起動で別のプロセスに使い回されうるので、ここでは見ない。
    if [ "$b" = "$boot" ]; then
        [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "claude" ] && continue
        [ "$DRY_RUN" = "1" ] || rm -f "$f"
        continue
    fi

    if [ ! -d "$cwd" ]; then
        log "skip $sid: $cwd が無い (worktree を消した後)"
        [ "$DRY_RUN" = "1" ] || mv "$f" "$STATE_DIR/resumed/$sid"
        continue
    fi

    kind=$(classify "$transcript")
    launched="$launched$wtid"$'\n'
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: resume $sid ($kind) → $cwd"
        continue
    fi
    # 先に印をどける。再開したセッションの SessionStart が同じ名前で新しい印を書くので、
    # 起動の後で消すと新しい印を消しかねない。
    mv "$f" "$STATE_DIR/resumed/$sid"
    if open_tab "$wtid" "$sid" "$kind" "$cwd"; then
        log "resume $sid ($kind) → $cwd"
    else
        log "failed to resume $sid → $cwd"
        orca worktree set --worktree "id:$wtid" --unread \
            --comment "再起動後のセッション再開に失敗: claude -r $sid" --json >/dev/null || true
    fi
    sleep "$LAUNCH_INTERVAL"
done

# ---- Needs decision のカードで、会話が開いていないものを開き直す ----
# 人の判断待ちのカードは、答えるための会話が開いていないと先へ進まない。ターミナルが 1 つも無い worktree は、
# その worktree の最後の対話セッションを開き直し、判断待ちがまだ残っているかを確かめさせる。
# 確かめさせる指示は会話全体を送り直す (セッションあたり数百円かかりうる) ので、同じ (worktree, セッション) には
# 1 回だけ。開き直したタブを人が閉じたら、それ以上は開かない。対話セッションの無い worktree は記録だけして触らない。
ORPHANS_FILE="$STATE_DIR/orphans.tsv"
touch "$ORPHANS_FILE"
while IFS=$'\t' read -r wtid wt; do
    [ -n "$wtid" ] || continue
    printf '%s' "$launched" | grep -qxF -- "$wtid" && continue

    # 最新の対話セッション (claude -p の sdk-cli は除く)。
    dir="$CLAUDE_HOME/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
    sid=-
    while IFS= read -r x; do
        # 記録は行単位で読み、最初に entrypoint が出たところで止める (先頭の 1 行が長くても切らない)。
        ep=$(jq -rn 'first(inputs | select(.entrypoint) | .entrypoint) // empty' "$x" 2>/dev/null || true)
        if [ "$ep" = "cli" ]; then
            sid=$(basename "$x" .jsonl)
            break
        fi
    done < <(ls -t "$dir"/*.jsonl 2>/dev/null || true)

    key="$wtid"$'\t'"$sid"
    grep -qxF -- "$key" "$ORPHANS_FILE" && continue
    if [ "$sid" = "-" ]; then
        log "skip $wt: Needs decision だが対話セッションが無い"
        [ "$DRY_RUN" = "1" ] || printf '%s\n' "$key" >>"$ORPHANS_FILE"
        continue
    fi
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: recheck $sid → $wt"
        continue
    fi
    # 記録は開けたときだけ。失敗したものは次の回にもう一度試す。
    if open_tab "$wtid" "$sid" recheck "$wt"; then
        printf '%s\n' "$key" >>"$ORPHANS_FILE"
        log "recheck $sid → $wt"
    else
        log "failed to reopen $sid → $wt (次の回にもう一度試す)"
    fi
    sleep "$LAUNCH_INTERVAL"
done < <(orca worktree ps --json 2>/dev/null | jq -r '
    (.result.worktrees // .result)[]?
    | select((.isMainWorktree | not) and .workspaceStatus == "needs-decision" and (.liveTerminalCount // 0) == 0)
    | [.worktreeId, .path] | @tsv')
