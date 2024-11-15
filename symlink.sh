#!/bin/bash

THIS_DIR=$(cd "$(dirname "$0")" || exit; pwd)

ZSH_DIR="$THIS_DIR/zsh"
GIT_DIR="$THIS_DIR/git"
VIM_DIR="$THIS_DIR/vim"

# 特別なファイルのリンク先を管理
get_special_dest() {
    local filename=$1
    case "$filename" in
        ".zshenv") echo "$HOME/.zshenv" ;;
        ".zshrc") echo "$HOME/.zshrc" ;;
        ".gitconfig") echo "$HOME/.gitconfig" ;;
        ".gitignore_global") echo "$HOME/.config/git/ignore" ;;
        ".vimrc") echo "$HOME/.vimrc" ;;
        *) echo "" ;;  # 特別な指定がない場合は空
    esac
}

# シンボリックリンクを貼るための関数
create_symlink() {
    local src=$1
    local dest=$2

    # 既存のファイル/リンクがある場合はバックアップ
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mv "$dest" "$dest.bak"
        echo "バックアップを作成しました: $dest.bak"
    fi

    # シンボリックリンクを作成
    ln -s "$src" "$dest"
    echo "シンボリックリンクを作成しました: $src -> $dest"
}

# 指定されたディレクトリでシンボリックリンクを作成
process_directory() {
    local src_dir=$1
    local default_dest_dir=$2
    mkdir -p "$default_dest_dir"

    find "$src_dir" -mindepth 1 -maxdepth 1 -type f | while read -r file; do
        local filename=$(basename "$file")
        local dest=$(get_special_dest "$filename")

        # 特別なリンク先がなければデフォルトのディレクトリを使用
        [ -z "$dest" ] && dest="$default_dest_dir/$filename"
        create_symlink "$file" "$dest"
    done
}

# 実行
process_directory "$ZSH_DIR" "$HOME/.config/zsh"
process_directory "$GIT_DIR" "$HOME/.config/git"
process_directory "$VIM_DIR" "$HOME"