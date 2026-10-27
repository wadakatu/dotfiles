#!/bin/sh
# agents/claude/hooks/branch-guard.sh の判定を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   sh tests/branch-guard.sh
set -u

hook="$(cd "$(dirname "$0")/.." && pwd)/agents/claude/hooks/branch-guard.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git init -q -b main "$tmp/on-main"
git init -q -b feature "$tmp/on-feature"

fail=0
check() { # check <want exit> <cwd> <command>
  got=$(jq -nc --arg c "$3" --arg d "$2" '{tool_input: {command: $c}, cwd: $d}' | sh "$hook" 2>/dev/null; echo $?)
  if [ "$got" != "$1" ]; then
    echo "FAIL want=$1 got=$got cwd=$2: $3"
    fail=1
  fi
}

main=$tmp/on-main
feat=$tmp/on-feature

check 2 "$main" 'git commit -m x'
check 2 "$feat" "git -C $main commit -m x"
check 2 "$feat" "git -C $main -c user.name=x commit -m x"
check 2 "$feat" 'git push origin main'
check 2 "$feat" "git -C $feat push origin main"
check 2 "$feat" 'git -c push.default=current push origin HEAD:dev'
check 2 "$feat" 'git --no-pager push origin feature:master'
check 0 "$feat" 'git commit -m x'
check 0 "$feat" "git -C $feat push origin feature"
# -C の前に別のオプションがあっても、cwd ではなく -C の先で判定する
check 0 "$main" "git -c user.name=x -C $feat commit -m x"
check 0 "$main" "git --no-pager -C $feat commit -m x"
check 2 "$feat" "git --no-pager -c user.name=x -C $main commit -m x"
check 0 "$main" 'git log --oneline'
check 0 "$main" "git -C $main status"

[ "$fail" = 0 ] && echo "branch-guard: all checks passed"
exit "$fail"
