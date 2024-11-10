# Dotfiles

This repository contains configuration files (dotfiles) to quickly set up a macOS development environment. It includes settings for Homebrew installation of applications, iTerm2, vim, zsh, and more.

## Structure

```shell
.
├── Brewfile   # List of applications to install via Homebrew
├── git/       # Git configuration files
├── iterm/     # iTerm2 configuration files
├── vim/       # Vim configuration files
├── zsh/       # Zsh configuration files
├── README.md  # This file
├── init.sh    # Main script for environment setup
└── symlink.sh # Script to create symlinks for dotfiles
```
## Usage

1. **Clone the repository**

   ```bash
   git clone https://github.com/yourusername/dotfiles.git
   cd dotfiles
   ```

2. **Run the initialization script**

   ```bash
   sh init.sh
   ```


3. Setup complete

  Running the above command will:
  
  - Install applications listed in Brewfile using Homebrew.
  - Execute symlink.sh to create symlinks for each configuration file (git, iterm, vim, zsh) in your home directory.

