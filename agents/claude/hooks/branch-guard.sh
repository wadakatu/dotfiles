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
  payload_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
else
  cmd=$input
  payload_cwd=""
fi

case $cmd in
  *"git commit"*|*"git push"*) ;;
  *) exit 0 ;;
esac

# Which repository does this command actually act on? CLAUDE_PROJECT_DIR is
# only the session's root, and several projects keep sibling checkouts inside
# it (dev-docker has app/, auth/, front/). Judging those by the outer repo's
# HEAD blocks every commit in a sub-repo whenever the outer one sits on master.
#
# Order: an explicit `git -C <dir>` beats the session cwd, which beats the
# project dir. A relative -C path is resolved against the cwd git itself would
# use, so the three stay consistent.
dir=${CLAUDE_PROJECT_DIR:-$PWD}
[ -n "$payload_cwd" ] && [ -d "$payload_cwd" ] && dir=$payload_cwd

target=$(printf '%s' "$cmd" \
  | sed -n "s/.*git[[:space:]][[:space:]]*-C[[:space:]][[:space:]]*\([^[:space:]]*\).*/\1/p" \
  | head -n1 \
  | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
if [ -n "$target" ]; then
  case $target in
    /*) dir=$target ;;
    *)  dir="$dir/$target" ;;
  esac
fi

branch=$(git -C "$dir" symbolic-ref --short -q HEAD) || exit 0

for p in $PROTECTED; do
  if [ "$branch" = "$p" ]; then
    echo "branch-guard: HEAD is on protected branch '$branch' ($dir)." >&2
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
