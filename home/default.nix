{ pkgs, ... }: {
  # imports: 機能ごとに分割した子モジュールを取り込む。
  # 子モジュールも (pkgs, ...) を受け取り、option を merge していく。
  imports = [
    ./zsh.nix
    ./git.nix
    ./vim.nix
  ];

  # ユーザー識別。/Users/koyoisono が home-manager の管理対象。
  home.username = "koyoisono";
  home.homeDirectory = "/Users/koyoisono";

  # home.stateVersion: home-manager のデフォルト値の互換ベースライン。
  # 一度決めたら基本的には上げない (確認: home-manager release notes)。
  home.stateVersion = "26.05";

  # home-manager 自身を home-manager で管理する宣言 (再帰的)。
  # これで `home-manager` コマンドが PATH に入る。
  programs.home-manager.enable = true;
}
