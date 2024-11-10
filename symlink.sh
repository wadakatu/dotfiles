#!/bin/bash

THIS_DIR=$(cd "$(dirname $0)" || exit; pwd)

ZSH_DIR="$THIS_DIR/zsh"
CONFIG_ZSH_DIR="$HOME/.config/zsh"
GIT_DIR=$THIS_DIR/git
CONFIG_GIT_DIR="$HOME/.config/git"
VIM_DIR=$THIS_DIR/vim

# シンボリックリンクを貼るための関数
create_symlink() {
    src=$1
    dest=$2

    # 既存のファイル/リンクがある場合はバックアップ
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mv "$dest" "$dest.bak"
        echo "バックアップを作成しました: $dest.bak"
    fi

    # シンボリックリンクを作成
    ln -s "$src" "$dest"
    echo "シンボリックリンクを作成しました: $src -> $dest"
}

# ~/.config/zsh ディレクトリが存在しない場合は作成
mkdir -p "$CONFIG_ZSH_DIR"
mkdir -p "$CONFIG_GIT_DIR"

# dotglobを有効にして隠しファイルも取得
shopt -s dotglob

# zshディレクトリ内の各ファイルをループ
for file in "$ZSH_DIR"/*; do
    filename=$(basename "$file")

    if [ "$filename" = ".zshenv" ] || [ "$filename" = ".zshrc" ]; then
        create_symlink "$file" "$HOME/$filename"
    else
        create_symlink "$file" "$CONFIG_ZSH_DIR/$filename"
    fi
done

# gitディレクトリ内の各ファイルをループ
for file in "$GIT_DIR"/*; do
    filename=$(basename "$file")

    if [ "$filename" = ".gitconfig" ]; then
        create_symlink "$file" "$HOME/$filename"
    fi

    if [ "$filename" = ".gitignore_global" ]; then
        create_symlink "$file" "$CONFIG_GIT_DIR/ignore"
    fi
done

# vimディレクトリ内の各ファイルをループ
for file in "$GIT_DIR"/*; do
    filename=$(basename "$file")

    if [ "$filename" = ".vimrc" ]; then
        create_symlink "$file" "$HOME/$filename"
    fi
done

# dotglobの設定を元に戻す
shopt -u dotglob