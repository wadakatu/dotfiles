{ ... }: {
  # Phase 4: macOS システム設定の宣言化。
  # system.defaults.<domain>.<key> は switch 時に root 権限で `defaults write` を実行し、
  # Dock / Finder を再起動して即反映する。手動 GUI 設定はここで上書きされる点に注意。
  # オプション名・型は nix-darwin の pin 済みソース (rev 56c666e) で確認済み。
  # 全オプションは nullOr 型 = 未設定(null)なら macOS デフォルトのまま触らない。
  system.defaults = {

    # ── Dock ─────────────────────────────────────────────
    dock = {
      autohide = true; # Dock を自動的に隠す
      autohide-delay = 0.0; # ホバーから表示までの遅延 (秒)。0 で即表示
      show-recents = false; # 「最近使ったアプリ」を Dock に出さない
      mru-spaces = false; # スペースを最近の使用順に並べ替えない (デスクトップ配置が固定される)
      tilesize = 48; # アイコンサイズ (px)
      magnification = false; # ホバー時の拡大を無効
      minimize-to-application = true; # 最小化したウィンドウをアプリアイコンに格納
      show-process-indicators = true; # 起動中アプリのインジケータ点を表示
      orientation = "bottom"; # Dock の位置: "bottom" | "left" | "right"

      # ホットコーナー (任意): wvous-{tl,tr,bl,br}-corner に整数コードを入れる。
      # 1=無効 2=Mission Control 4=デスクトップ表示 5=スクリーンセーバ開始
      # 11=Launchpad 13=画面ロック 14=クイックメモ
      # 例) 右下を画面ロックにする場合:
      # wvous-br-corner = 13;
    };

    # ── Finder ───────────────────────────────────────────
    finder = {
      AppleShowAllExtensions = true; # 拡張子を常に表示
      ShowPathbar = true; # 下部にパスバーを表示
      ShowStatusBar = true; # 下部にステータスバーを表示
      _FXShowPosixPathInTitle = true; # タイトルバーにフルパスを表示
      FXPreferredViewStyle = "Nlsv"; # 既定の表示: "Nlsv"=リスト "icnv"=アイコン "clmv"=カラム "Flwv"=ギャラリー
      FXEnableExtensionChangeWarning = false; # 拡張子変更時の警告を出さない
      _FXSortFoldersFirst = true; # フォルダを先頭にまとめてソート
      AppleShowAllFiles = false; # 隠しファイルは非表示 (true で表示)
    };

    # ── キーボード / 入力 (NSGlobalDomain) ────────────────
    NSGlobalDomain = {
      InitialKeyRepeat = 15; # キー長押しからリピート開始までの時間 (小さいほど速い)
      KeyRepeat = 2; # リピート間隔 (小さいほど速い)
      ApplePressAndHoldEnabled = false; # 長押しでアクセント候補ではなくキーリピートさせる (vim 向き)
      NSAutomaticCapitalizationEnabled = false; # 自動大文字化オフ
      NSAutomaticDashSubstitutionEnabled = false; # ダッシュの自動置換オフ
      NSAutomaticQuoteSubstitutionEnabled = false; # スマートクオート置換オフ
      NSAutomaticPeriodSubstitutionEnabled = false; # ピリオドの自動挿入オフ
      NSAutomaticSpellingCorrectionEnabled = false; # 自動スペル修正オフ
      AppleShowAllExtensions = true; # 拡張子表示 (finder と揃える)
    };

    # ── スクリーンショット ───────────────────────────────
    screencapture = {
      # 保存先。screencapture は "~" を展開しないので絶対パスで指定する。
      # フォルダ自体は home-manager 側 (home/default.nix) で作成する。
      location = "/Users/koyoisono/Screenshots";
      type = "png"; # 保存形式
      disable-shadow = true; # ウィンドウ撮影時の影を付けない
      show-thumbnail = true; # 撮影後にサムネイルを表示
    };
  };
}
