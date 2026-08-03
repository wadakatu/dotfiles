{ ... }: {
  # nix-darwin の homebrew モジュール (Phase 3)。
  # GUI アプリは自動更新・Spotlight 連携の都合で Homebrew cask のまま管理する方針 (CLAUDE.md)。
  # nix-darwin は Brewfile を生成して `brew bundle` を回すだけで、Homebrew 本体は別途インストール済みが前提。
  homebrew = {
    enable = true;

    # onActivation: darwin-rebuild switch 時の brew の挙動。
    #   cleanup: 生成 Brewfile に無い formula/cask の扱い。値は "none" | "check" | "uninstall" | "zap"。
    #     - "none"     : 何もしない (既存の手動 brew install を消さない)
    #     - "uninstall": Brewfile に無いものをアンインストール
    #     - "zap"      : uninstall + 設定ファイルまで完全削除
    #   移行期は破壊的でない "none" にしておき、Brewfile への列挙が出揃ってから "zap" へ上げる。
    #   autoUpdate / upgrade も activation のたびに走ると遅く・非決定的なので false。
    onActivation = {
      cleanup = "none";
      autoUpdate = false;
      upgrade = false;
    };

    # tenvはterraform/tofu/terragrunt等のフロントエンドをまとめて提供するため、
    # Homebrew formulaとして管理して現在のバージョン切り替え方法を維持する。
    brews = [
      "tenv"
    ];

    # 旧 Brewfile の cask 群。token はそのまま流用。
    # 旧 tap "homebrew/bundle" / "homebrew/services" は upstream 廃止 + nix-darwin が
    # Brewfile を自前生成するため不要。意図的に持ち込まない。
    casks = [
      "1password"
      # macOS の公式導入手順に合わせ、デスクトップアプリ連携を使う CLI も
      # Homebrew cask で管理する。認証情報と ~/.config/op は管理対象外。
      "1password-cli"
      "chatgpt"
      "claude"
      # OpenAIのGitHub Releaseにあるstandalone binaryをcask経由で導入し、
      # Node.jsランタイムとは独立させつつdotfilesから再現可能にする。
      "codex"
      "discord"
      # 旧 Brewfile は "docker" だったが、現在の Homebrew では正式 token が
      # "docker-desktop" にリネームされている (旧名は deprecated エイリアス)。
      "docker-desktop"
      "elgato-wave-link"
      "herd"
      "ghostty"
      # 普段使いのブラウザではなく、Puppeteer / CDP 経由の動作確認用。
      # chrome-devtools MCP は実在の Chrome バイナリに接続する仕組みで、
      # Safari は接続先にならないため必要。
      "google-chrome"
      "logi-options+"
      "notion"
      "slack"
      "zen"
    ];
  };
}
