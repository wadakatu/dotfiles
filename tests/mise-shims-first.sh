#!/usr/bin/env bash
# agents/claude/hooks/mise-shims-first.sh が CLAUDE_ENV_FILE に書く式を、Bash ツールの zsh と bash で読み込んで確かめる。
#   bash tests/mise-shims-first.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
hook="$root/agents/claude/hooks/mise-shims-first.sh"
base=$(mktemp -d) || exit 1
trap 'rm -rf "$base"' EXIT
fail=0
m="/h/.local/share/mise"
nl='
'

echo 'export OTHER=1' >"$base/env" # 他の hook の書き込み
# 2 回走らせても 1 回分だけ書き、先にある行は残す。
HOME=/h CLAUDE_ENV_FILE="$base/env" /bin/bash "$hook" </dev/null
HOME=/h CLAUDE_ENV_FILE="$base/env" /bin/bash "$hook" </dev/null
[ "$(grep -c '^__m=' "$base/env")" = 1 ] || { echo "FAIL 2 回走らせると重複する"; fail=1; }
grep -qx 'export OTHER=1' "$base/env" || { echo "FAIL 他の hook の行が消えた"; fail=1; }
shells=(/bin/bash)
[ -x /bin/zsh ] && shells+=(/bin/zsh)

expect() { # expect <説明> <PATH> <期待>
    for sh in "${shells[@]}"; do
        # shellcheck disable=SC2016  # '...' の中の $IN と $1 は呼んだシェルが展開する
        got=$(HOME=/h IN="$2" "$sh" -c 'PATH=$IN; . "$1"; printf "%s." "$PATH"' _ "$base/env")
        [ "$got" = "$3." ] || { echo "FAIL $1 ($sh): got '$got' want '$3.'"; fail=1; }
    done
}

expect "最初の installs の直前に入る" \
    "/orca/bin:$m/installs/pnpm/9.15.0:$m/installs/node/23/bin:$m/shims:/usr/bin" \
    "/orca/bin:$m/shims:$m/installs/pnpm/9.15.0:$m/installs/node/23/bin:$m/shims:/usr/bin"
expect "installs が先頭でも入る" "$m/installs/node/23/bin:/usr/bin" "$m/shims:$m/installs/node/23/bin:/usr/bin"
expect "前にある開発シェルの bin は動かさない" \
    "/nix/store/x-node/bin:$m/installs/node/23/bin:/usr/bin" \
    "/nix/store/x-node/bin:$m/shims:$m/installs/node/23/bin:/usr/bin"
expect "installs が無ければ変えない" "/usr/bin:/bin:$m/shims" "/usr/bin:/bin:$m/shims"
expect "空白・' ・改行・末尾の空要素を保つ" \
    "/a b/bin:/c'd:/e${nl}f:$m/installs/node/23/bin:/usr/bin:" \
    "/a b/bin:/c'd:/e${nl}f:$m/shims:$m/installs/node/23/bin:/usr/bin:"
expect "要素の途中の installs には反応しない" "/x$m/installs/y:/usr/bin" "/x$m/installs/y:/usr/bin"
HOME=/h CLAUDE_ENV_FILE="" /bin/bash "$hook" </dev/null || { echo "FAIL CLAUDE_ENV_FILE 無しで落ちる"; fail=1; }

[ "$fail" = 0 ] && echo "ok (${shells[*]})"
exit "$fail"
