{ lib, username, homeDirectory, ... }: {
  # imports: 機能ごとに分割した子モジュールを取り込む。
  # 子モジュールの option は Home Manager によって merge される。
  imports = [
    ./zsh.nix
    ./git.nix
    ./mise.nix
    ./neovim.nix
    ./ghostty.nix
    ./herdr.nix
    ./packages.nix
    ./worktree-gc.nix
  ];

  # ユーザー識別は flake.nix の1か所を正とする。
  home.username = username;
  home.homeDirectory = homeDirectory;

  # home.stateVersion: home-manager のデフォルト値の互換ベースライン。
  # 一度決めたら基本的には上げない (確認: home-manager release notes)。
  home.stateVersion = "26.05";

  # home-manager 自身を home-manager で管理する宣言 (再帰的)。
  # これで `home-manager` コマンドが PATH に入る。
  programs.home-manager.enable = true;

  # スクリーンショット保存先フォルダを用意する (system/defaults.nix の
  # screencapture.location と対。root ではなくユーザー権限で作るため home-manager 側)。
  # lib.hm.dag.entryAfter ["writeBoundary"] = dotfile のリンク確定後に実行する activation。
  home.activation.createScreenshotsDir =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "$HOME/Screenshots"
    '';
}
