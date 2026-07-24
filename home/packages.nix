{ pkgs, ... }: {
  # 旧 Brewfile の CLI formula を nixpkgs に移行 (Phase 3)。
  # home.packages は home-manager がユーザープロファイル (~/.nix-profile) に入れる。
  # GUI cask は system レベルの modules/homebrew.nix 側で管理する。
  #
  # ripgrep はシェルからの利用に加え、Neovim Telescope の live_grep に必要。
  # 旧 Brewfile 由来の gcc/libwebp は現環境で明示利用されていないため外した。
  home.packages = with pkgs; [
    age
    glow
    google-cloud-sdk
    imagemagick
    jq
    ripgrep
    uv
    yq-go
  ];
}
