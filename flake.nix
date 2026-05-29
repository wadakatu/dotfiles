{
  # Phase 1: 最小構成。nix-darwin が動くことを確認するためだけの flake。
  # Phase 2 以降で home-manager / Homebrew / macOS 設定を順次足していく。
  description = "wadakatu's macOS system flake";

  # inputs: この flake が依存する外部リソース。
  # flakehub URL は Determinate Systems が提供する SemVer ピン留め対応の参照方法。
  # 公式の Determinate 連携ガイド (https://docs.determinate.systems/guides/nix-darwin/) に準拠。
  inputs = {
    # Determinate Nix の nix-darwin 連携モジュール。これを使うと nix-darwin 側の
    # Nix 管理（services.nix-daemon 等）が無効化され、Determinate がインストールした
    # Nix デーモンと衝突しなくなる。
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";

    # nixpkgs: ほぼ全てのパッケージが含まれる本体。
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";

    # nix-darwin: macOS をシステムレベルで宣言的に管理するための仕組み。
    nix-darwin = {
      url = "https://flakehub.com/f/nix-darwin/nix-darwin/0";
      # 同じ nixpkgs を共有させ、ストア肥大化と挙動の食い違いを防ぐ。
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # home-manager: ユーザー領域 (~/) のドットファイル・パッケージ・サービスを
    # 宣言的に管理。nix-darwin の中にモジュールとして組み込んで使う。
    home-manager = {
      url = "https://flakehub.com/f/nix-community/home-manager/0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs, determinate, home-manager }:
    let
      # configuration: 1台のホストに適用する設定モジュール。
      # 引数 { pkgs, ... } は nix-darwin が自動的に渡してくれる。
      configuration = { pkgs, ... }: {
        # Determinate にインストールされた Nix を使う宣言。
        # これを true にすることで nix-darwin 側の nix.* 系オプションは無効化される。
        # customSettings = {} は /etc/nix/nix.custom.conf (Determinate が作成するファイル) の
        # 所有権を nix-darwin に渡す宣言。これを書かないと "Unexpected files in /etc" で
        # activation が中断する (https://github.com/LnL7/nix-darwin/issues/1298)。
        determinateNix = {
          enable = true;
          customSettings = { };
        };

        # ユーザー宣言。home-manager の nixos/common.nix が
        # config.users.users.<name>.home から home.homeDirectory を導出するため、
        # ここで宣言しないと null になり「homeDirectory is not of type 'absolute path'」エラー。
        users.users.koyoisono = {
          name = "koyoisono";
          home = "/Users/koyoisono";
        };

        # nix-darwin は system activation を root で実行する方式へ移行した。
        # homebrew.* など「実行ユーザーに紐づく」オプションは、root ではなく
        # この primaryUser に適用される。homebrew.enable を使うには宣言必須。
        system.primaryUser = "koyoisono";

        # システムにインストールされるパッケージ。動作確認用に vim を1つだけ。
        # ユーザー領域の CLI ツールは home/packages.nix (home.packages) 側で管理する。
        environment.systemPackages = [ pkgs.vim ];

        # darwin-version コマンドが返す revision に git commit hash を埋め込む。
        system.configurationRevision = self.rev or self.dirtyRev or null;

        # 後方互換用。changelog を読まずに変更しないこと。
        # 確認コマンド: darwin-rebuild changelog
        system.stateVersion = 6;

        # Apple Silicon。Intel Mac なら "x86_64-darwin"。
        nixpkgs.hostPlatform = "aarch64-darwin";
      };
    in
    {
      # darwinConfigurations.<name>: nix-darwin が読むホスト設定の集合。
      # 名前 "mymac" は hostname に依存しない論理名。新しい Mac でも使い回せる。
      # ビルド: darwin-rebuild switch --flake .#mymac
      darwinConfigurations."mymac" = nix-darwin.lib.darwinSystem {
        modules = [
          determinate.darwinModules.default
          home-manager.darwinModules.home-manager
          configuration
          ./modules/homebrew.nix
          ./system/defaults.nix
          {
            # useGlobalPkgs: home-manager に独自の nixpkgs を持たせず、
            # nix-darwin と同じ nixpkgs を共有。ストア肥大化を防ぐ。
            home-manager.useGlobalPkgs = true;
            # useUserPackages: home.packages を ~/.nix-profile 配下に置く。
            # 副作用として nix-env でインストールしたものと衝突しなくなる。
            home-manager.useUserPackages = true;
            # 既存 ~/.zshrc 等と衝突した場合は .before-hm を付けてバックアップ。
            # 初回 activation で既存 dotfiles symlink を自動退避できる。
            home-manager.backupFileExtension = "before-hm";
            home-manager.users.koyoisono = import ./home/default.nix;
          }
        ];
      };
    };
}
