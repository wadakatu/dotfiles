{ pkgs, ... }: {
  # 旧 Brewfile の CLI formula を nixpkgs に移行 (Phase 3)。
  # home.packages は home-manager がユーザープロファイル (~/.nix-profile) に入れる。
  # GUI cask は system レベルの modules/homebrew.nix 側で管理する。
  #
  # 移行の対応関係:
  #   brew "gcc"                    → pkgs.gcc      (GNU Compiler Collection)
  #   brew "webp"                   → pkgs.libwebp  (cwebp/dwebp 同梱。formula 名と attr 名が違う点に注意)
  #   brew "zsh-autosuggestions"    → programs.zsh.autosuggestion.enable    で Phase 2 に吸収済み
  #   brew "zsh-completions"        → programs.zsh.enableCompletion         で Phase 2 に吸収済み
  #   brew "zsh-syntax-highlighting"→ programs.zsh.syntaxHighlighting.enable で Phase 2 に吸収済み
  #   brew "zsh-git-prompt"         → starship に移行済み (nixpkgs から削除されたため)
  home.packages = with pkgs; [
    gcc
    libwebp
  ];
}
