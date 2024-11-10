zstyle ":completion:*:commands" rehash 1
if type brew &>/dev/null; then

  ####################################################
  # zsh-completions
  # https://github.com/zsh-users/zsh-completions
  ####################################################
  FPATH=$(brew --prefix)/share/zsh-completions:$FPATH

  ####################################################
  # zsh-autosuggestions
  # https://github.com/zsh-users/zsh-autosuggestions
  ####################################################
  if [ -f "$(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ]; then
      source "$(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
  fi

  ####################################################
  # zsh-syntax-highlighting
  # https://github.com/zsh-users/zsh-syntax-highlighting
  ####################################################
  if [ -f "$(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]; then
    source "$(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
  fi

  ####################################################
  # zsh-git-prompt
  # https://github.com/olivierverdier/zsh-git-prompt
  ####################################################
  if [ -f "$(brew --prefix)/opt/zsh-git-prompt/zshrc.sh" ]; then
    source "$(brew --prefix)/opt/zsh-git-prompt/zshrc.sh"
  fi

  autoload -Uz compinit && compinit
fi