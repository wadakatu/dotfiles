{ config, dotfilesDir, ... }: {
  # 自分の OPEN な PR を 30 分ごとに見て、conflict / CI 失敗 / 未対応のレビューがあれば
  # Orca のタブでエージェントを起動する LaunchAgent。対象は Orca に worktree がある非 draft の PR。
  #
  # 判定をスクリプトで回すのは worktree-gc と同じ理由で、材料 (mergeable、CI の結果、
  # 未解決スレッドの最後の発言者) が機械的に決まるため。AI は対応が要るときだけ起動する。
  launchd.agents.pr-dispatch = {
    enable = true;
    config = {
      # スクリプト実体はリポジトリの絶対パスを直接叩く (worktree-gc.nix と同じ判断)。
      ProgramArguments = [
        "/bin/bash"
        "${dotfilesDir}/home/scripts/pr-dispatch.sh"
      ];

      # 30 分ごと。スリープ中は走らず、起床後に次の周期から再開する。
      StartInterval = 1800;

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pr-dispatch.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pr-dispatch.log";

      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
