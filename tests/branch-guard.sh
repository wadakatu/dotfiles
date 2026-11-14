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
check 2 "$feat" 'git push origin HEAD:refs/heads/dev'
check 2 "$feat" 'git push origin refs/heads/main'
check 0 "$feat" 'git push origin HEAD:refs/heads/feature'
check 0 "$feat" 'git commit -m x'
check 0 "$feat" "git -C $feat push origin feature"
# -C の前に別のオプションがあっても、cwd ではなく -C の先で判定する
check 0 "$main" "git -c user.name=x -C $feat commit -m x"
check 0 "$main" "git --no-pager -C $feat commit -m x"
check 2 "$feat" "git --no-pager -c user.name=x -C $main commit -m x"
# detached HEAD でも、保護ブランチを名指しする push は止める（commit は止めない）
git -C "$feat" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$feat" worktree add -q --detach "$tmp/detached"
det=$tmp/detached
check 2 "$det" 'git push origin HEAD:main'
check 2 "$feat" "git -C $det push origin HEAD:refs/heads/dev"
check 0 "$det" 'git push origin HEAD:refs/heads/feature'
check 0 "$det" 'git commit -m x'
check 0 "$main" 'git log --oneline'
check 0 "$main" "git -C $main status"
# 先頭の `cd <絶対パス> && …` だけは cd 先で判定する
check 0 "$main" "cd $feat && git add -A && git commit -m x"
check 0 "$main" "  cd \"$feat\" && git commit -m x"
check 0 "$main" "cd $tmp && git -C on-feature commit -m x"
check 2 "$main" "cd $tmp && git -C on-main commit -m x"
check 2 "$feat" "cd $main && git commit -m x"
check 2 "$main" "cd $feat && git push origin HEAD:main"
# それ以外の形は、これまでどおりセッションの cwd で判定する
check 2 "$main" "(cd $feat); git commit -m x"
check 2 "$main" "false && cd $feat; git commit -m x"
check 2 "$main" "cd $feat | cat; git commit -m x"
check 2 "$main" "W=$main; (W=$feat); cd \"\$W\"; git commit -m x"
check 2 "$main" "cd $feat; git commit -m x"
check 2 "$main" "cd $feat && true || git commit -m x"
check 2 "$main" "cd $feat && sleep 1 & git commit -m x"
check 2 "$main" "cd $feat && git commit -m x & git push"
check 0 "$main" "cd $feat && git add -A 2>&1 && git commit -m x >/dev/null 2>&1"
check 2 "$main" "cd $feat && git switch main && git commit -m x"
check 2 "$main" "cd $feat && git commit -m x && cd $main && git commit -m y"
check 2 "$main" "cd $tmp/missing && git commit -m x; git commit -m y"
# 止めたときは git -C での書き直しを案内する
msg=$(jq -nc --arg c 'git commit -m x' --arg d "$main" '{tool_input: {command: $c}, cwd: $d}' | sh "$hook" 2>&1 >/dev/null)
case $msg in
  *"git -C"*) ;;
  *) echo "FAIL message lacks git -C: $msg"; fail=1 ;;
esac

[ "$fail" = 0 ] && echo "branch-guard: all checks passed"
exit "$fail"
