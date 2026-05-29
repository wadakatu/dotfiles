{ pkgs, lib, ... }: {
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    # 旧 plugins.zsh の brew 経由ロードを home-manager の一級オプションに置換。
    # nixpkgs から本体を取得して自動 source される。
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    # 旧 aliases.zsh
    shellAliases = {
      python = "python3";
    };

    # 環境変数。.zshenv 相当の文脈で展開される。
    sessionVariables = {
      VOLTA_HOME = "$HOME/.volta";
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
      export HERD_PHP_74_INI_SCAN_DIR="$HOME/Library/Application Support/Herd/config/php/74/"
    '';
  };

  # 旧 paths.zsh。home.sessionPath は PATH の末尾に追加される。
  # /usr/bin 等の標準パスは macOS デフォルトで既に通っているので列挙不要。
  home.sessionPath = [
    "/opt/homebrew/bin"
    "/opt/homebrew/sbin"
    "$HOME/Library/Application Support/Herd/bin"
    "$HOME/.volta/bin"
    "$HOME/.cargo/bin"
    "$HOME/.local/bin"
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
    settings = {
      add_newline = true;
      # 旧プロンプトの "wadakatu(arm64):dir git-status\n$" に近い構成。
      # %~ → $directory、git_super_status → $git_branch + $git_status。
      format = lib.concatStrings [
        "[wadakatu](bold green)"
        "($hostname)"
        ":$directory"
        "$git_branch$git_status"
        "$line_break"
        "$character"
      ];
      hostname = {
        ssh_only = false;
        format = "([$hostname](bold green))";
      };
      directory = {
        truncation_length = 3;
        truncate_to_repo = false;
      };
      character = {
        success_symbol = "[\\$](bold green)";
        error_symbol = "[\\$](bold red)";
      };
    };
  };
}
