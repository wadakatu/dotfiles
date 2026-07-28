{ config, ... }: {
  # herdr 本体は herdr 自身の updater (`herdr update`) が ~/.local/bin へ入れるので
  # Nix では管理せず、設定ファイルだけをリポジトリ側に置く。

  # ghostty のように `.source = ./config/...` で書くと /nix/store への読み取り専用
  # symlink になるが、herdr は config.toml を自分で書き換えるため使えない
  #   - オンボーディング完了時に `onboarding = false` を書き込む
  #   - `herdr config reset-keys` が config.toml をバックアップして書き換える
  # ~/.claude を symlink にしていないのと同じ理由 (README「エージェントスキルとコマンド」)。
  #
  # mkOutOfStoreSymlink: home-manager が /nix/store を経由せず、指定した絶対パスへ
  # 直接 symlink を張るためのヘルパー。実体はリポジトリ側の1ファイルだけになり、
  #   - 書き込み可能なので herdr 自身の書き換えが通る
  #   - その書き換えがそのまま `git status` に出る
  #   - 設定をいじるたびの darwin-rebuild が不要
  # という状態になる。flake では相対パス (./config/...) を渡すと flake source の
  # store コピーを指してしまうため、絶対パスの文字列を渡す (home-manager#2085)。
  xdg.configFile."herdr/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/www/dotfiles/home/config/herdr/config.toml";
}
