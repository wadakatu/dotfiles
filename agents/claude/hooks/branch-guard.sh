#!/bin/sh
# branch-guard: PreToolUse(Bash) hook for Claude Code and Codex.
#
# Blocks `git commit` / `git push` while HEAD is on a protected branch,
# and pushes that explicitly target a protected branch from anywhere.
# Guards only agent-driven Bash commands; manual git in a terminal is
# unaffected. Exit 2 = block (stderr goes back to the agent), exit 0 = allow.
# Both agents send the same payload (tool_input.command, cwd).
#
# Register in ~/.claude/settings.json:
#   "PreToolUse": [{ "matcher": "Bash", "hooks": [
#     { "type": "command", "command": "/Users/wadakatu/.claude/hooks/branch-guard.sh" } ] }]
# Codex gets it from /etc/codex/hooks.json, which modules/codex.nix generates.

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

# Match on the command with git's global options removed, so that
# `git -C repo push`, `git -c k=v commit` and `git --no-pager push` are
# checked like `git push` / `git commit`.
# ponytail: values are split on whitespace, so a quoted value with spaces
# (`git -c "k=a b" commit`) still slips through; parse argv if that shows up.
norm=$(printf '%s' "$cmd" \
  | sed -E 's/git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))+/git/g')

case $norm in
  *"git commit"*|*"git push"*) ;;
  *) exit 0 ;;
esac

# Which repository does this command actually act on? CLAUDE_PROJECT_DIR is
# only the session's root, and some projects keep sibling checkouts nested
# inside an outer repository. Judging those by the outer repo's HEAD blocks
# every commit in a sub-repo whenever the outer one sits on master.
#
# Order: an explicit `git -C <dir>` beats a leading `cd` (below), which beats
# the session cwd, which beats the project dir. A relative -C path is resolved
# against the cwd git itself would use, so they stay consistent.
dir=${CLAUDE_PROJECT_DIR:-$PWD}
[ -n "$payload_cwd" ] && [ -d "$payload_cwd" ] && dir=$payload_cwd

# One cd form is followed, because agents write it for sibling repos:
# `cd /abs/path && ...` at the very start, with nothing before the first
# commit/push that could run elsewhere (subshell, pipe, `;`, `||`, newline),
# and nowhere a `&` (it backgrounds the cd), another cd, or a command that
# moves HEAD (checkout/switch/branch). The "nowhere" part reads the raw
# command, since $norm swallows option values like `-c k=v&`. Anything else
# keeps the cwd, since reading shell loosely would let currently blocked
# commands through.
# ponytail: a deny list, so env -C, GIT_DIR=... and the like still retarget
# git unseen; add them here if they show up.
cd_dir=$(printf '%s\n' "$cmd" | head -n1 \
  | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"[^\"]*\"|'[^']*'|[^[:space:]\"']+)[[:space:]]*&&.*/\1/p" \
  | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
case $cd_dir in
  /*[!-[:alnum:]._/@+,:=\ ]*|"") ;;
  /*)
    rest=${norm#*&&}
    pre=${rest%%git commit*}
    p=${rest%%git push*}
    [ ${#p} -lt ${#pre} ] && pre=$p
    case $pre in *'
'*) ;;
    *)
      printf '%s' "$pre" | grep -Eq '[;|()`]' \
        || printf '%s' "${cmd#*&&}" | grep -Eq '(^|[^&>])&([^&>]|$)|(^|[^[:alnum:]_./-])(cd|pushd|popd|switch|checkout|branch)([^[:alnum:]_./-]|$)' \
        || { [ -d "$cd_dir" ] && dir=$cd_dir; }
      ;;
    esac
    ;;
esac

target=$(printf '%s' "$cmd" \
  | sed -nE 's/.*git([[:space:]]+(-c[[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\4/p' \
  | head -n1 \
  | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")
if [ -n "$target" ]; then
  case $target in
    /*) dir=$target ;;
    *)  dir="$dir/$target" ;;
  esac
fi

# Per-repo opt-out for repos that deliberately ship straight to main
# (e.g. a solo, experimental tool): `git config branchguard.allowProtected true`.
# Lives in the repo's own .git/config, so its worktrees share it.
[ "$(git -C "$dir" config --bool branchguard.allowProtected 2>/dev/null)" = true ] && exit 0

# Detached HEAD (or not a repo) has no branch to protect, but an explicit push
# to a protected ref must still be checked below, so don't exit early.
branch=$(git -C "$dir" symbolic-ref --short -q HEAD) || branch=""

for p in $PROTECTED; do
  if [ "$branch" = "$p" ]; then
    echo "branch-guard: HEAD is on protected branch '$branch' ($dir)." >&2
    echo "Create a feature branch first (e.g. git switch -c feature/<topic>) and retry." >&2
    echo "This hook does not follow cd (only a leading 'cd /abs/path && ...'). For another repository, use git -C <absolute path> instead." >&2
    exit 2
  fi
  case $norm in
  *"git push"*)
    # Catch pushes naming a protected ref: `git push origin main`,
    # `git push origin HEAD:dev`, `git push origin feature:main`,
    # `git push origin HEAD:refs/heads/dev`.
    if printf '%s' "$norm" | grep -Eq "git push[^&|;]*([[:space:]]|:)(refs/heads/)?${p}([[:space:]]|:|\$)"; then
      echo "branch-guard: this push explicitly targets protected branch '$p'. Open a PR instead." >&2
      exit 2
    fi
    ;;
  esac
done

exit 0
