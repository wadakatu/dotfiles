#!/usr/bin/env bash
# home/scripts/live-sync.sh を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/live-sync.sh
# git は本物で、一時ディレクトリに作ったリモートと checkout を使う。
# skill・rule・LaunchAgent のスクリプトが読む場所を作るスクリプトなので、
# 「失敗しても前の版が残る」「同時に動いても壊れない」を主に見る。
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/live-sync.sh"
base=$(mktemp -d)
base=$(cd "$base" && pwd -P)
export GIT_CONFIG_GLOBAL="$base/gitconfig" GIT_CONFIG_NOSYSTEM=1 # 手元の hook や署名の設定を巻き込まない
git config -f "$GIT_CONFIG_GLOBAL" user.name t
git config -f "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
git config -f "$GIT_CONFIG_GLOBAL" init.defaultBranch main
# 取り出した先は読み取り専用なので、消す前に書き込めるようにする。
trap 'chmod -R u+w "$base" 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
CASE=""
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}

# ---- リモートと checkout ----
git init -q --bare "$base/origin.git"
git clone -q "$base/origin.git" "$base/repo" 2>/dev/null
repo="$base/repo"
commit() { # commit <メッセージ> : home/scripts と agents に 1 行足して origin/main を進める
    mkdir -p "$repo/home/scripts" "$repo/agents/skills/demo" "$repo/agents/claude/rules"
    echo "echo $1" >"$repo/home/scripts/hello.sh"
    echo "$1" >"$repo/agents/skills/demo/SKILL.md"
    echo "$1" >"$repo/agents/claude/rules/r.md"
    echo "$1" >"$repo/outside.txt" # 取り出す対象の外
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "$1"
    git -C "$repo" push -q origin HEAD:main
    git -C "$repo" fetch -q origin main
}
commit v1
sha1=$(git -C "$repo" rev-parse origin/main)
live="$base/live"
sync() { LIVE_SYNC_NO_FETCH=1 bash "$script" "$repo" "$live"; }
points_to() { [ "$(readlink "$live/current")" = "$1" ]; }
versions() { find "$live" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' '; }
no_leftover() { [ -z "$(find "$live" -name '.tmp.*' -o -name '.current.*')" ]; }

CASE="初回"
out=$(sync)
check "取り出したパスを出力する" [ "$out" = "$live/$sha1" ]
check "スクリプトがある" [ "$(cat "$live/current/home/scripts/hello.sh")" = "echo v1" ]
check "skill がある" [ "$(cat "$live/current/agents/skills/demo/SKILL.md")" = "v1" ]
check "対象外のファイルは取り出さない" [ ! -e "$live/current/outside.txt" ]
check "current がその版を指す" points_to "$sha1"
check "読み取り専用" [ ! -w "$live/$sha1/agents/skills/demo/SKILL.md" ]
check "ディレクトリも読み取り専用" [ ! -w "$live/$sha1/agents/skills" ]
check "一時ファイルが残らない" no_leftover

CASE="変化なしの 2 回目"
out=$(sync)
check "同じパスを出力する" [ "$out" = "$live/$sha1" ]
check "版は 1 つのまま" [ "$(versions)" = 1 ]

CASE="origin/main が進む"
commit v2
sha2=$(git -C "$repo" rev-parse origin/main)
out=$(sync)
check "新しい版を出力する" [ "$out" = "$live/$sha2" ]
check "current が新しい版に移る" points_to "$sha2"
check "新しい中身が読める" [ "$(cat "$live/current/agents/claude/rules/r.md")" = "v2" ]
check "古い版は残る (実行中のスクリプトが使っているかもしれない)" [ "$(cat "$live/$sha1/home/scripts/hello.sh")" = "echo v1" ]
check "一時ファイルが残らない" no_leftover

CASE="取り出しの途中で失敗"
commit v3
sha3=$(git -C "$repo" rev-parse origin/main)
mkdir -p "$base/bin"
# archive だけ、途中まで出力してから失敗する git。
cat >"$base/bin/git-fail-archive" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "archive" ]; then
        printf 'broken'
        exit 1
    fi
done
exec git "$@"
EOF
chmod +x "$base/bin/git-fail-archive"
GIT="$base/bin/git-fail-archive" LIVE_SYNC_NO_FETCH=1 bash "$script" "$repo" "$live" >/dev/null 2>&1
check "失敗を exit で返す" [ $? -ne 0 ]
check "current は前の版のまま" points_to "$sha2"
check "中途半端な版を置かない" [ ! -e "$live/$sha3" ]
check "一時ファイルが残らない" no_leftover
out=$(sync)
check "次の回で取り出せる" [ "$out" = "$live/$sha3" ]
check "current が進む" points_to "$sha3"

CASE="同じ版を 2 つ同時に取り出す"
commit v4
sha4=$(git -C "$repo" rev-parse origin/main)
# archive を遅らせて、両方が「まだ無い」と判断してから取り出すようにする。
cat >"$base/bin/git-slow-archive" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    [ "$a" = "archive" ] && sleep 1
done
exec git "$@"
EOF
chmod +x "$base/bin/git-slow-archive"
GIT="$base/bin/git-slow-archive" LIVE_SYNC_NO_FETCH=1 bash "$script" "$repo" "$live" >"$base/out-a" 2>&1 &
pa=$!
GIT="$base/bin/git-slow-archive" LIVE_SYNC_NO_FETCH=1 bash "$script" "$repo" "$live" >"$base/out-b" 2>&1 &
pb=$!
wait "$pa"
ra=$?
wait "$pb"
rb=$?
check "片方が成功する" [ "$ra" -eq 0 ]
check "もう片方も成功する" [ "$rb" -eq 0 ]
check "両方が同じ版を出力する" [ "$(cat "$base/out-a")" = "$live/$sha4" ]
check "両方が同じ版を出力する (2)" [ "$(cat "$base/out-b")" = "$live/$sha4" ]
check "中身が壊れていない" [ "$(cat "$live/$sha4/home/scripts/hello.sh")" = "echo v4" ]
check "版の中に一時ディレクトリが入り込まない" [ -z "$(find "$live/$sha4" -name '.tmp.*')" ]
check "一時ファイルが残らない" no_leftover
check "current がその版を指す" points_to "$sha4"

CASE="fetch"
# リモートだけ進める (手元の origin/main は古いまま)。
git clone -q "$base/origin.git" "$base/other" 2>/dev/null
echo "echo v5" >"$base/other/home/scripts/hello.sh"
git -C "$base/other" commit -q -am v5
git -C "$base/other" push -q origin HEAD:main
sha5=$(git -C "$base/other" rev-parse HEAD)
out=$(sync)
check "LIVE_SYNC_NO_FETCH=1 なら fetch しない" [ "$out" = "$live/$sha4" ]
out=$(bash "$script" "$repo" "$live")
check "直前に fetch していれば fetch しない (15 分に 1 回まで)" [ "$out" = "$live/$sha4" ]
rm -f "$repo/.git/FETCH_HEAD"
out=$(bash "$script" "$repo" "$live")
check "しばらく fetch していなければ fetch して新しい版にする" [ "$out" = "$live/$sha5" ]
check "current が進む" points_to "$sha5"

CASE="origin/main が無い"
git init -q "$base/empty"
LIVE_SYNC_NO_FETCH=1 bash "$script" "$base/empty" "$base/live2" >/dev/null 2>&1
check "失敗を exit で返す" [ $? -ne 0 ]
check "current を作らない" [ ! -e "$base/live2/current" ]

[ "$fail" = 0 ] && echo "live-sync: all checks passed"
exit "$fail"
