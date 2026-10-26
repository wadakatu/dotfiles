{ homeDirectory, pkgsUnstable, ... }: {
  # 言語ランタイムは現環境に合わせて mise に一本化する。
  # 原則は移行時点のバージョンを固定する。PythonはCodex・Claudeの汎用処理向けに
  # 最新安定版を使い、プロジェクト固有の設定がある場合はそちらを優先する。
  programs.mise = {
    enable = true;
    # 安定版 26.05 の mise (2026.5.12) は、studio-auth の mise.toml の min_version
    # (2026.9.16) を満たさないので unstable から取る。
    # nixpkgs が 26.11 (2026-11 末リリース予定) に上がったら外す。
    package = pkgsUnstable.mise;
    enableZshIntegration = true;

    globalConfig = {
      tools = {
        bun = "1.1.38";
        node = "23.4.0";
        pnpm = "9.15.0";
        python = "latest";
        yarn = "1.22.19";
      };

      settings.idiomatic_version_file_enable_tools = [ "node" ];
      # Orca が作る worktree はパスが毎回新しく、未 trust のままだと mise shim
      # 経由の node が失敗して Claude Code の hook（ponytail 等）がエラーになる。
      settings.trusted_config_paths = [ "${homeDirectory}/orca/workspaces" ];
    };
  };
}
