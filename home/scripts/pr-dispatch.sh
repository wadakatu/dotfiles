#!/usr/bin/env bash
#
# 自分の OPEN な PR を見て、対応が要るものに Orca のタブでエージェントを起動する。
# 対象は Orca に worktree がある非 draft の PR だけ。
#   conflict → /sync-pr、CI 失敗 → /fix-ci、未対応のレビュー → /review-pr-comments
# あわせて、人の判断待ちになったものを Orca のボードに出す。
#   同じ対応を MAX_ATTEMPTS 回起動しても直らない PR → Needs decision
#   CLEAN で auto-merge の無い PR (マージするかは人が決める) → Needs decision
#   入力待ち (waiting) のエージェント → Needs decision
#   文章で質問して止まったエージェント (Orca では done に見える) → 未読と「要確認」のコメントだけ付ける
# launchd から数分ごとに実行される。定義は home/pr-dispatch.nix。
#
# 手で確認するとき:
#   DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/pr-dispatch.sh
#
set -euo pipefail

# launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin だけで、orca も gh も jq も入らない。
PATH="/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
# launchd の環境にはロケールが無く、cut -c がバイト単位で切って日本語のコメントが文字化けする。
export LC_ALL=en_US.UTF-8

ORCA_ROOT="${ORCA_ROOT:-$HOME/orca/workspaces}"
# 起動済みの (PR, 対応, 状態) を 1 行ずつ覚える。直せなかった状態に周期ごと起動し直さないため。
# 状態が変われば (新しい push、新しいレビュー) キーが変わり、また起動する。
STATE_FILE="${STATE_FILE:-$HOME/Library/Application Support/pr-dispatch/dispatched.tsv}"
# ボードに書いた (worktree, 理由, 状態) を 1 行ずつ覚える。数分ごとに同じ状態を書き直して、
# 人が消した未読の印を付け直さないため。
BOARD_FILE="${BOARD_FILE:-$HOME/Library/Application Support/pr-dispatch/board.tsv}"
# 1 回の実行で起動する上限。base の更新で conflict が一斉に出たときに、エージェントを並べすぎない。
MAX_LAUNCHES="${MAX_LAUNCHES:-3}"
# 同じ PR に同じ対応を起動する回数の上限。超えたら人に上げる (自動の修正が空回りし続けないため)。
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
# 数分ごとに同じ内容が並ぶ見送りの理由は、VERBOSE=1 のときだけ出す。
vlog() { [ "$VERBOSE" = "1" ] && log "$@"; return 0; }

flagged=0
# board <path> <reason> <sig> <status|-> <comment>
# (path, reason, sig) を初めて見たときだけボードに書く。status が - なら列は動かさず未読とコメントだけ付ける。
board() {
    local wt=$1 reason=$2 sig=$3 status=$4 comment=$5 key
    key="$wt"$'\t'"$reason"$'\t'"$sig"
    grep -qxF -- "$key" "$BOARD_FILE" && return 0
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: board $reason → ${wt#"$ORCA_ROOT"/} ($status) $comment"
        flagged=$((flagged + 1))
        return 0
    fi
    local args=(--worktree "path:$wt" --unread --comment "$comment" --json)
    [ "$status" = "-" ] || args+=(--workspace-status "$status")
    if orca worktree set "${args[@]}" >/dev/null 2>&1; then
        printf '%s\n' "$key" >>"$BOARD_FILE"
        log "board $reason → ${wt#"$ORCA_ROOT"/}: $comment"
        flagged=$((flagged + 1))
    else
        log "WARN: ボードに書けない $reason → $wt (次回に再試行)"
    fi
}

# 最後の発言が人への質問で終わっているか。末尾の数行に疑問符か依頼の言い回しがあれば質問とみなす。
# ponytail: 文末の決まり文句だけで見ている。誤判定が多ければ、エージェントに決まった印を書かせる方式に切り替える。
looks_like_question() {
    printf '%s' "$1" | awk 'NF' | tail -n 3 | grep -Eq '[?？]|ますか|ですか|でしょうか|ください|教えて'
}

if ! orca status --json 2>/dev/null | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1; then
    log "Orca のランタイムに届かない。見送り (次回に拾う)"
    exit 0
fi

me=$(gh api user -q .login)
mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$BOARD_FILE")"
touch "$STATE_FILE" "$BOARD_FILE"

# ---- Orca の worktree: "<owner/repo>\t<branch>\t<path>\t<board status>" ----
worktrees=""
while IFS=$'\t' read -r wt_path branch status; do
    [ -n "$branch" ] || continue
    slug=$(git -C "$wt_path" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') || continue
    [ -n "$slug" ] || continue
    worktrees="$worktrees$slug"$'\t'"$branch"$'\t'"$wt_path"$'\t'"$status"$'\n'
done < <(orca worktree list --json | jq -r --arg root "$ORCA_ROOT" '
    .result.worktrees[]
    | select((.isMainWorktree | not) and (.path | startswith($root + "/")))
    | [.path, ((.branch // "") | sub("^refs/heads/"; "")), (.workspaceStatus // "")] | @tsv')

if [ -z "$worktrees" ]; then
    log "Orca の worktree が無い。終了"
    exit 0
fi

# ---- PR の状態を 1 回の問い合わせで取る (検索は worktree のあるリポに絞る) ----
repos=$(printf '%s' "$worktrees" | cut -f1 | sort -u | sed 's/^/repo:/' | tr '\n' ' ')
search="is:pr is:open draft:false archived:false author:$me $repos"
# shellcheck disable=SC2016  # $q は GraphQL の変数。シェルに展開させない
prs_json=$(gh api graphql -f q="$search" -f query='
query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        number
        url
        headRefName
        headRefOid
        mergeable
        mergeStateStatus
        autoMergeRequest { enabledAt }
        repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        reviewThreads(first: 100) {
          nodes { isResolved comments(last: 1) { nodes { id author { login } } } }
        }
      }
    }
  }
}' 2>/dev/null) || {
    log "WARN: GitHub から PR を取れない。見送り"
    exit 0
}
# 未対応のレビュー = 未解決のスレッドのうち、最後の発言が自分以外のもの。その発言 ID の並びを状態に使う。
# 無いときは "-"。空欄にすると read がタブの連続を 1 つに詰め、後ろの列がずれる。
prs=$(jq -r --arg me "$me" '.data.search.nodes[]
    | [ .repository.nameWithOwner, .headRefName, (.number | tostring), .url, .headRefOid, .mergeable,
        (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"),
        ([.reviewThreads.nodes[] | select((.isResolved | not) and (.comments.nodes[0].author.login != $me))
          | .comments.nodes[0].id] | sort | join(",") | if . == "" then "-" else . end),
        .mergeStateStatus, (if .autoMergeRequest then "auto" else "manual" end) ] | @tsv' <<<"$prs_json")
ps_json=$(orca worktree ps --json 2>/dev/null || echo '{}')

launched=0
while IFS=$'\t' read -r slug branch num url head mergeable ci threads merge_state merge_mode; do
    [ -n "$slug" ] || continue
    line=$(printf '%s' "$worktrees" | awk -F'\t' -v s="$slug" -v b="$branch" '$1 == s && $2 == b { print; exit }')
    [ -n "$line" ] || continue
    wt=$(printf '%s' "$line" | cut -f3)
    board=$(printf '%s' "$line" | cut -f4)
    pr="$slug#$num"

    if [ "$mergeable" = "CONFLICTING" ]; then
        action="sync-pr"; sig="$head"
    elif [ "$ci" = "FAILURE" ] || [ "$ci" = "ERROR" ]; then
        action="fix-ci"; sig="$head"
    elif [ "$threads" != "-" ]; then
        action="review-pr-comments"; sig="$head:$threads"
    else
        # 対応が要らない PR。CLEAN で auto-merge が無ければ、マージするかは人が決める。
        if [ "$merge_state" = "CLEAN" ] && [ "$merge_mode" = "manual" ] && [ "$board" != "needs-decision" ]; then
            board "$wt" merge "$head" needs-decision "マージ判断: #$num（CLEAN・auto-merge なし）"
        fi
        continue
    fi

    if [ "$board" = "needs-decision" ]; then
        vlog "keep  $pr ($action 候補だが Needs decision でユーザーの判断待ち)"
        continue
    fi
    busy=$(jq -r --arg p "$wt" '[.result.worktrees[]? | select(.path == $p) | .agents[]?.state | select(. != "done")] | join(",")' <<<"$ps_json")
    if [ -n "$busy" ]; then
        vlog "keep  $pr ($action 候補だがエージェントが $busy)"
        continue
    fi
    key="$pr"$'\t'"$action"$'\t'"$sig"
    if grep -qxF -- "$key" "$STATE_FILE"; then
        continue
    fi
    attempts=$(grep -cF -- "$pr"$'\t'"$action"$'\t' "$STATE_FILE" || true)
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        board "$wt" "give-up-$action" "$sig" needs-decision "自動の /$action を $attempts 回起動しても直らない: #$num"
        continue
    fi
    if [ "$launched" -ge "$MAX_LAUNCHES" ]; then
        vlog "keep  $pr ($action: 今回の起動上限 $MAX_LAUNCHES に達した。次回)"
        continue
    fi

    prompt="/$action $url

(pr-dispatch による自動起動。人は見ていない。判断が要るものはグローバル CLAUDE.md の「委任の線引き」どおり Needs decision に上げて止まる)"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: launch $action → $pr ($wt)"
        launched=$((launched + 1))
        continue
    fi
    if orca agent launch --agent claude --worktree "path:$wt" --prompt "$prompt" --json 2>/dev/null | jq -e '.ok == true' >/dev/null; then
        printf '%s\n' "$key" >>"$STATE_FILE"
        orca worktree set --worktree "path:$wt" --comment "auto: $action (#$num)" --json >/dev/null 2>&1 || true
        log "launch $action → $pr"
        launched=$((launched + 1))
    else
        log "WARN: 起動に失敗 $action → $pr (次回に再試行)"
    fi
done <<<"$prs"

# ---- エージェントの状態をボードに出す (PR の有無に関係なく、Orca の全 worktree が対象) ----
# 最新のエージェント 1 体を見る。waiting は Orca が入力待ちと判定したもの。
# done でも、最後の発言が質問なら人待ちなので、列は動かさず未読と「要確認」だけ付ける。
# 発言の改行は 1 行 1 worktree に収めるため " ⏎ " にして渡し、ループの中で戻す。
while IFS=$'\t' read -r wt board state since last; do
    [ -n "$wt" ] || continue
    [ "$board" = "needs-decision" ] && continue
    last=${last// ⏎ /$'\n'}
    first=$(printf '%s' "$last" | awk 'NF' | tail -n 1 | cut -c1-80)
    if [ "$state" = "waiting" ]; then
        board "$wt" waiting "$since" needs-decision "入力待ち: ${first:-エージェントが入力を待っている}"
    elif [ "$state" = "done" ] && looks_like_question "$last"; then
        board "$wt" question "$since" - "要確認: $first"
    fi
done < <(jq -r --arg root "$ORCA_ROOT" '
    .result.worktrees[]?
    | select((.isMainWorktree | not) and (.path | startswith($root + "/")) and ((.agents // []) | length > 0))
    | (.agents | max_by(.updatedAt // 0)) as $a
    | [.path, ((.workspaceStatus // "") | if . == "" then "-" else . end), $a.state, (($a.stateStartedAt // 0) | tostring),
       (($a.lastAssistantMessage // "") | gsub("[\t\r]"; " ") | gsub("\n"; " ⏎ "))] | @tsv' <<<"$ps_json")

if [ "$launched" -gt 0 ] || [ "$flagged" -gt 0 ]; then
    log "完了 (起動: $launched, ボード: $flagged)"
fi
