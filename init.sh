#!/bin/bash
THIS_DIR=$(cd "$(dirname "$0")" || exit; pwd)

echo "Dotfiles installation started."

# Rosetta
if ! sudo softwareupdate --install-rosetta --agree-to-license; then
    echo "Rosetta installation failed." >&2
    exit 1
fi

# Dotfiles
sh "${THIS_DIR}/symlink.sh"

# Homebrew
if ! type "brew" >/dev/null 2>&1; then
    echo "installing Homebrew ..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        echo "Error: Homebrew installation failed." >&2
        exit 1
    fi
fi

echo "run brew doctor ..."
brew doctor || { echo "brew doctor failed" >&2; exit 1; }

echo "run brew update ..."
brew update || { echo "brew update failed" >&2; exit 1; }

echo "run brew upgrade ..."
brew upgrade || { echo "brew upgrade failed" >&2; exit 1; }

echo "run brew bundle ..."
brew bundle --file="${THIS_DIR}/Brewfile" || { echo "brew bundle failed" >&2; exit 1; }

echo "run brew cleanup ..."
brew cleanup || { echo "brew cleanup failed" >&2; exit 1; }

# zshを使用している場合のみ再読み込み
if [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
    source "$HOME/.zshrc"
fi