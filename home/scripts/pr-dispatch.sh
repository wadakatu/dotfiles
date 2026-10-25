#!/usr/bin/env bash
#
# 自分の OPEN な PR を見て、対応が要るものに Orca のタブでエージェントを起動する。
# 対象は Orca に worktree がある非 draft の PR だけ。
#   conflict → /sync-pr、CI 失敗 → /fix-ci、未対応のレビュー → /review-pr-comments
# launchd から 30 分ごとに実行される。定義は home/pr-dispatch.nix。
#
# 手で確認するとき:
#   DRY_RUN=1 ~/www/dotfiles/home/scripts/pr-dispatch.sh
#
set -euo pipefail

# launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin だけで、orca も gh も jq も入らない。
PATH="/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

ORCA_ROOT="${ORCA_ROOT:-$HOME/orca/workspaces}"
# 起動済みの (PR, 対応, 状態) を 1 行ずつ覚える。直せなかった状態に 30 分ごと起動し直さないため。
# 状態が変われば (新しい push、新しいレビュー) キーが変わり、また起動する。
STATE_FILE="${STATE_FILE:-$HOME/Library/Application Support/pr-dispatch/dispatched.tsv}"
# 1 回の実行で起動する上限。base の更新で conflict が一斉に出たときに、エージェントを並べすぎない。
MAX_LAUNCHES="${MAX_LAUNCHES:-3}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if ! orca status --json 2>/dev/null | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1; then
    log "Orca のランタイムに届かない。見送り (次回に拾う)"
    exit 0
fi

me=$(gh api user -q .login)
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

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
prs=$(jq -r --arg me "$me" '.data.search.nodes[]
    | [ .repository.nameWithOwner, .headRefName, (.number | tostring), .url, .headRefOid, .mergeable,
        (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"),
        ([.reviewThreads.nodes[] | select((.isResolved | not) and (.comments.nodes[0].author.login != $me))
          | .comments.nodes[0].id] | sort | join(",")) ] | @tsv' <<<"$prs_json")
ps_json=$(orca worktree ps --json 2>/dev/null || echo '{}')

launched=0
while IFS=$'\t' read -r slug branch num url head mergeable ci threads; do
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
    elif [ -n "$threads" ]; then
        action="review-pr-comments"; sig="$head:$threads"
    else
        continue
    fi

    if [ "$board" = "needs-decision" ]; then
        log "keep  $pr ($action 候補だが Needs decision でユーザーの判断待ち)"
        continue
    fi
    busy=$(jq -r --arg p "$wt" '[.result.worktrees[]? | select(.path == $p) | .agents[]?.state | select(. != "done")] | join(",")' <<<"$ps_json")
    if [ -n "$busy" ]; then
        log "keep  $pr ($action 候補だがエージェントが $busy)"
        continue
    fi
    key="$pr"$'\t'"$action"$'\t'"$sig"
    if grep -qxF -- "$key" "$STATE_FILE"; then
        continue
    fi
    if [ "$launched" -ge "$MAX_LAUNCHES" ]; then
        log "keep  $pr ($action: 今回の起動上限 $MAX_LAUNCHES に達した。次回)"
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

log "完了 (起動: $launched)"
