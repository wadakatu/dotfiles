{ ... }: {
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    # 旧 plugins.zsh の brew 経由ロードを home-manager の一級オプションに置換。
    # nixpkgs から本体を取得して自動 source される。
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    # 現行 ~/.zshrc のエイリアス。
    shellAliases = {
      sail = "./vendor/bin/sail";
    };

    # 旧 .zshrc の Herd 注入分。手動メンテナンス方針 (CLAUDE.md 参照)。
    # PHP バージョンを Herd で追加・削除したら、ここの行も追従させる。
    initContent = ''
      # Herd injected PHP configurations (manually maintained — not auto-managed)
      export HERD_PHP_85_INI_SCAN_DIR="$HOME/Library/Application Support/Herd/config/php/85/"
      export HERD_PHP_84_INI_SCAN_DIR="$HOME/Library/Application Support/Herd/config/php/84/"
      export HERD_PHP_83_INI_SCAN_DIR="$HOME/Library/Application Support/Herd/config/php/83/"
      export HERD_PHP_82_INI_SCAN_DIR="$HOME/Library/Application Support/Herd/config/php/82/"
      export HERD_PHP_81_INI_SCAN_DIR="$HOME/Library/Application Support/Herd/config/php/81/"

      # Bun の補完ファイルは Bun が生成した場合だけ読み込む。
      if [[ -s "$HOME/.bun/_bun" ]]; then
        source "$HOME/.bun/_bun"
      fi
    '';
  };

  # 旧 paths.zsh。home.sessionPath は PATH の末尾に追加される。
  # /usr/bin 等の標準パスは macOS デフォルトで既に通っているので列挙不要。
  home.sessionPath = [
    "$HOME/.local/share/mise/shims"
    "$HOME/Library/Application Support/Herd/bin"
    "$HOME/.cargo/bin"
    "$HOME/.local/bin"
    "$HOME/.opencode/bin"
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
  ];

  # 旧 .fzf.zsh 全部を置き換え。シェル統合と key-bindings/completion を有効化。
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # 旧 prompts.zsh の置換。zsh-git-prompt は upstream unmaintained で
  # nixpkgs から削除されたため (2025-08-28)、starship に乗り換え。
  # デフォルトのままでも見やすい。気に入らなければ settings を後で調整。
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = builtins.fromTOML (builtins.readFile ./config/starship.toml);
  };
}
