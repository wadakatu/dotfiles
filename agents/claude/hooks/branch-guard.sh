#!/bin/sh
# branch-guard: PreToolUse(Bash) hook for Claude Code.
#
# Blocks `git commit` / `git push` while HEAD is on a protected branch,
# and pushes that explicitly target a protected branch from anywhere.
# Guards only Claude-driven Bash commands; manual git in a terminal is
# unaffected. Exit 2 = block (stderr goes back to Claude), exit 0 = allow.
#
# Register in ~/.claude/settings.json:
#   "PreToolUse": [{ "matcher": "Bash", "hooks": [
#     { "type": "command", "command": "/Users/wadakatu/.claude/hooks/branch-guard.sh" } ] }]

PROTECTED="main master dev"

input=$(cat)

# Extract the Bash command from the hook payload. jq is accurate; the raw
# fallback over-matches (payload noise) but only costs a false block.
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
else
  cmd=$input
fi

case $cmd in
  *"git commit"*|*"git push"*) ;;
  *) exit 0 ;;
esac

dir=${CLAUDE_PROJECT_DIR:-$PWD}
branch=$(git -C "$dir" symbolic-ref --short -q HEAD) || exit 0

for p in $PROTECTED; do
  if [ "$branch" = "$p" ]; then
    echo "branch-guard: HEAD is on protected branch '$branch'." >&2
    echo "Create a feature branch first (e.g. git switch -c feature/<topic>) and retry." >&2
    exit 2
  fi
  case $cmd in
  *"git push"*)
    # Catch pushes naming a protected ref: `git push origin main`,
    # `git push origin HEAD:dev`, `git push origin feature:main`.
    if printf '%s' "$cmd" | grep -Eq "git push[^&|;]*([[:space:]]|:)${p}([[:space:]]|:|\$)"; then
      echo "branch-guard: this push explicitly targets protected branch '$p'. Open a PR instead." >&2
      exit 2
    fi
    ;;
  esac
done

exit 0
