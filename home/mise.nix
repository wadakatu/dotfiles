{ ... }: {
  # 言語ランタイムは現環境に合わせて mise に一本化する。
  # 原則は移行時点のバージョンを固定する。PythonはCodex・Claudeの汎用処理向けに
  # 最新安定版を使い、プロジェクト固有の設定がある場合はそちらを優先する。
  programs.mise = {
    enable = true;
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
    };
  };
}
