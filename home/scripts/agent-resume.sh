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
# launchd からログイン時と 3 分ごとに実行される。定義は home/agent-resume.nix。
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
PATH="/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL=en_US.UTF-8

STATE_DIR="${STATE_DIR:-$HOME/Library/Application Support/agent-resume}"
# 再開の間隔。ログイン直後に claude を一斉に立ち上げて、Orca のターミナル起動の制限に掛からないため。
LAUNCH_INTERVAL="${LAUNCH_INTERVAL:-5}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

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

# "{ sec = 1792979048, usec = 168067 } Mon Oct 26 ..." の sec。session-marker.sh と同じ値にする。
boot=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
mkdir -p "$STATE_DIR/sessions" "$STATE_DIR/resumed"
# この回で再開した worktree。下の Needs decision の節で二重に開かないため。
launched=""

for f in "$STATE_DIR/sessions"/*; do
    [ -f "$f" ] || continue
    sid=${f##*/}
    IFS=$'\t' read -r b pid wtid cwd transcript <"$f" || continue

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
    if orca terminal create --worktree "id:$wtid" --title "再開" \
        --command "bash '${BASH_SOURCE[0]}' launch '$sid' '$kind' '$cwd'" --json >/dev/null; then
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
    dir="$HOME/.claude/projects/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"
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
    if orca terminal create --worktree "id:$wtid" --title "再開" \
        --command "bash '${BASH_SOURCE[0]}' launch '$sid' recheck '$wt'" --json >/dev/null; then
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
