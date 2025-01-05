#!/bin/bash
THIS_DIR=$(cd "$(dirname "$0")" || exit; pwd)

echo "Dotfiles installation started."

# Rosetta
if ! sudo softwareupdate --install-rosetta --agree-to-license; then
    echo "::error::Rosetta installation failed." >&2
    exit 1
fi

# Dotfiles
sh "${THIS_DIR}/symlink.sh" || { echo "::error::Symlink setup failed"; exit 1; }

# Homebrew
sh "${THIS_DIR}/brew.sh" || { echo "::error::Homebrew setup failed"; exit 1; }

# zshを使用している場合のみ再読み込み
if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
    source "$HOME/.zshrc"
fi