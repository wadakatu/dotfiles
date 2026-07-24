{ ... }: {
  # Ghostty 本体は GUI アプリなので Homebrew cask、設定だけを Home Manager で管理する。
  xdg.configFile."ghostty/config".source = ./config/ghostty/config;
}
