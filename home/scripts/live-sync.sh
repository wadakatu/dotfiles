#!/usr/bin/env bash
#
# origin/main の home/scripts と agents を、コミットごとのディレクトリに取り出す。
#   live-sync.sh <dotfiles の checkout> <取り出し先>
# 取り出したディレクトリのパスを標準出力に 1 行出す。<取り出し先>/current は最新の版への symlink。
#
# LaunchAgent のスクリプト (home/run-from-main.nix) と、skill・rule・エージェント定義 (home/agent-skills.nix) は
# ここから読む。作業ツリーがどのブランチに居ても、効くのは main にマージした版になる。
#
# - 取り出しは一時ディレクトリで終えてから rename する。途中で失敗しても current は前の版のまま。
# - 取り出した先は読み取り専用にする。その場で直しても次のマージで別の版に切り替わるので、直せないほうが安全。
# - 古い版は消さない。実行中のスクリプトや、後から起動されるパス (agent-resume が Orca のタブに渡す自分のパス) が
#   まだ使っているかを、経過時間では判定できないため。
#   ponytail: 溜まる一方 (1 版あたり数百 KB)。気になったら current が指す版以外を手で消す。
#
# このスクリプト自身は nix store から動く (取り出し先を作る側なので、取り出し先には置けない)。直したら rebuild が要る。
# macOS の BSD のコマンドでも、Home Manager の activation と CI が使う GNU のコマンドでも動くように書く。
set -euo pipefail

repo=$1
live=$2
git=${GIT:-git}

# fetch は 15 分に 1 回まで。3 分ごとの LaunchAgent が毎回 GitHub に問い合わせないようにする。
if [ "${LIVE_SYNC_NO_FETCH:-0}" != "1" ] && [ -z "$(find "$repo/.git/FETCH_HEAD" -mmin -15 2>/dev/null)" ]; then
    "$git" -C "$repo" fetch --quiet origin main ||
        echo "WARN: dotfiles の fetch に失敗。手元の origin/main で続ける" >&2
fi

sha=$("$git" -C "$repo" rev-parse --verify --quiet 'origin/main^{commit}') || {
    echo "ERROR: $repo に origin/main が無い" >&2
    exit 1
}

mkdir -p "$live"
tmp="$live/.tmp.$$"
link="$live/.current.$$"
cleanup() {
    if [ -e "$tmp" ]; then
        chmod -R u+w "$tmp" 2>/dev/null || true
        rm -rf "$tmp"
    fi
    rm -f "$link"
}
trap cleanup EXIT

if [ ! -d "$live/$sha" ]; then
    mkdir "$tmp"
    "$git" -C "$repo" archive "$sha" home/scripts agents | tar -xf - -C "$tmp"
    chmod -R a-w "$tmp"
    # 同じ版を別のプロセスが先に置いていたら、この mv は失敗する (置き先は読み取り専用で、中へは動かせない)。
    # そのときは先に置かれたものを使う。
    mv "$tmp" "$live/$sha" 2>/dev/null || [ -d "$live/$sha" ]
fi

if [ "$(readlink "$live/current" 2>/dev/null || true)" != "$sha" ]; then
    ln -s "$sha" "$link"
    # rename(2) で差し替える。ln -sfn は消してから作るので、その間 current が無くなる。
    # 「symlink の指す先へ動かさず、symlink 自体を置き換える」指定は GNU が -T、BSD が -h。
    if mv --version >/dev/null 2>&1; then
        mv -fT "$link" "$live/current"
    else
        mv -fh "$link" "$live/current"
    fi
fi

printf '%s\n' "$live/$sha"
