{ config, dotfilesDir, ... }: {
  # 放置された Claude / Codex のセッションを 10 分ごとに見つけて通知する LaunchAgent。
  # 止めるのはユーザーが `agent-gc stop` を打ったときだけで、Orca の端末に /exit を送る。
  # 中身は home/scripts/agent-gc.sh、設計は docs/agent-gc-design.md。
  launchd.agents.agent-gc = {
    enable = true;
    config = {
      # スクリプト実体はリポジトリの絶対パスを直接叩く (worktree-gc.nix と同じ判断)。閾値を変えても rebuild は要らない。
      ProgramArguments = [
        "/bin/bash"
        "${dotfilesDir}/home/scripts/agent-gc.sh"
        "scan"
      ];

      StartInterval = 600;

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/agent-gc.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/agent-gc.log";

      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };

  # 手で打つ list / stop 用。herdr.nix と同じく、store を経由せずリポジトリのスクリプトを直接指す。
  home.file.".local/bin/agent-gc".source =
    config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/home/scripts/agent-gc.sh";
}
