#!/bin/bash
#
# Stop hook: Orca の worktree で、エージェントが文章の質問で止まろうとしたら 1 回だけ差し戻す。
#
# 文章の質問は、Orca の Needs You にも Claude Code の agent view の Needs input にも出ず、
# 「完了」に見える。どちらも入力待ちとして数えるのは AskUserQuestion と許可の確認だけ。
# 人の判断を待つなら AskUserQuestion で聞くか、カードを Needs decision に移すよう、本人に返す。
# 待っているかどうかは本人が一番分かっているので、判定はモデルに任せ、ここでは差し戻すだけにする。
#
# settings.json の hooks.Stop から呼ぶ。stop_hook_active が true の回 (差し戻した直後) は何もしない。
set -u
export LC_ALL=en_US.UTF-8

input=$(cat)
[ -n "${ORCA_WORKTREE_ID:-}" ] || exit 0
[ "$(jq -r '.stop_hook_active // false' <<<"$input")" = "true" ] && exit 0

last=$(jq -r '.last_assistant_message // ""' <<<"$input" | awk 'NF' | tail -n 1)
printf '%s' "$last" | grep -Eq '[?？][[:space:]）)」』*]*$' || exit 0

status=$(orca worktree ps --json 2>/dev/null |
    jq -r --arg id "$ORCA_WORKTREE_ID" '(.result.worktrees // .result)[]? | select(.worktreeId == $id) | .workspaceStatus // ""')
[ "$status" = "needs-decision" ] && exit 0

jq -n '{hookSpecificOutput: {hookEventName: "Stop", additionalContext:
  "文章の質問で止まろうとしています。文章の質問は Orca のボードにも Needs You にも出ず、ユーザーから見ると完了に見えます。ユーザーの判断を待つなら、AskUserQuestion で聞き直すか、`orca worktree set --worktree current --workspace-status needs-decision --unread --comment \"<何を判断してほしいか 1 行>\" --json` でカードを移してから止まってください。判断を待っていない (報告や任意の提案だけ) なら、質問で終わらない文に直して止まってください。"}}'
