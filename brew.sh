#!/bin/bash

if [ "$(uname)" != "Darwin" ] ; then
	echo "Not macOS!"
	exit 1
fi

echo "run installing Homebrew ..."
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { echo "installing Homebrew failed" >&2; exit 1; }

echo "run brew update ..."
brew update || { echo "brew update failed" >&2; exit 1; }

echo "run brew upgrade ..."
brew upgrade || { echo "brew upgrade failed" >&2; exit 1; }

echo "run brew bundle ..."
brew bundle --file="${THIS_DIR}" || { echo "brew bundle failed" >&2; exit 1; }

echo "run brew cleanup ..."
brew cleanup || { echo "brew cleanup failed" >&2; exit 1; }

echo "run brew autoremove ..."
brew autoremove || { echo "brew autoremove failed" >&2; exit 1; }

echo "run brew doctor ..."
brew doctor || { echo "brew doctor failed" >&2; exit 1; }