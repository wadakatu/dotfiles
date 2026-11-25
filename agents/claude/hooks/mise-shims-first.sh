#!/bin/bash
# SessionStart hook: Bash ツールの PATH で、mise の最初の installs/<tool>/<版> の直前にシムを入れ、
# 版をコマンドごとのカレントの mise.toml で選ばせる。
# Bash ツールは Claude プロセスの PATH を使い回す。起動したシェルの `mise activate` がそのディレクトリの
# installs を先頭に入れているので、そのままだと cd しても起動ディレクトリの版のまま。
# installs より前 (nix develop / devenv の bin など) は動かさない。installs が無ければ何もしない。
# CLAUDE_ENV_FILE は Bash のコマンドごとに先に実行される (https://code.claude.com/docs/en/hooks#persist-environment-variables)。
# 他の hook が足した PATH を消さないよう、値ではなくその時点の PATH に挿す式を書く。
# 分割しないので末尾の空要素や改行を含む要素も保つ。他の hook の書き込みを残すため追記する。
set -u
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
# resume / compact で SessionStart が同じファイルにもう一度走っても 1 回だけ書く。
mark='# mise-shims-first'
grep -qxF "$mark" "$CLAUDE_ENV_FILE" 2>/dev/null && exit 0
cat >>"$CLAUDE_ENV_FILE" <<'SH'
# mise-shims-first
__m="$HOME/.local/share/mise"
case ":$PATH" in
*:"$__m"/installs/*)
    __p=":$PATH"
    __pre=${__p%%:"$__m"/installs/*}
    __p="$__pre:$__m/shims${__p#"$__pre"}"
    PATH=${__p#:}
    export PATH
    ;;
esac
unset __m __p __pre
SH
