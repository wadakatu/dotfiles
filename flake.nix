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
      # macOS の short user name。ユーザー名とホームパスを各モジュールへ
      # 重複記述せず、新しい Mac でもここだけを確認すればよいようにする。
      username = "wadakatu";
      homeDirectory = "/Users/${username}";

      # configuration: 1台のホストに適用する設定モジュール。
      configuration = { ... }: {
        # Determinate にインストールされた Nix を使う宣言。
        # これを true にすることで nix-darwin 側の nix.* 系オプションは無効化される。
        # customSettings = {} は /etc/nix/nix.custom.conf (Determinate が作成するファイル) の
        # 所有権を nix-darwin に渡す宣言。Determinate導入直後の通常ファイルは初回activation前に
        # 内容を確認して .before-nix-darwin へ退避する (README参照)。この宣言がない場合も
        # "Unexpected files in /etc" でactivationが中断する。
        determinateNix = {
          enable = true;
          customSettings = { };
        };

        # ユーザー宣言。home-manager の nixos/common.nix が
        # config.users.users.<name>.home から home.homeDirectory を導出するため、
        # ここで宣言しないと null になり「homeDirectory is not of type 'absolute path'」エラー。
        users.users.${username} = {
          name = username;
          home = homeDirectory;
        };

        # nix-darwin は system activation を root で実行する方式へ移行した。
        # homebrew.* など「実行ユーザーに紐づく」オプションは、root ではなく
        # この primaryUser に適用される。homebrew.enable を使うには宣言必須。
        system.primaryUser = username;

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
        # nix-darwin モジュールへユーザー情報を渡す。
        specialArgs = { inherit username homeDirectory; };

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
            # Home Manager モジュールへも同じユーザー情報を渡す。
            home-manager.extraSpecialArgs = { inherit username homeDirectory; };
            # 既存 ~/.zshrc 等と衝突した場合は .before-hm を付けてバックアップ。
            # 初回 activation で既存 dotfiles symlink を自動退避できる。
            home-manager.backupFileExtension = "before-hm";
            home-manager.users.${username} = import ./home/default.nix;
          }
        ];
      };
    };
}
