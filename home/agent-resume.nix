{ config, dotfilesDir, ... }: {
  # Mac の再起動で止まった Claude のセッションを、Orca のタブで再開する LaunchAgent。
  # Orca は再起動でエージェントのプロセスを失うので (docs `model/session-restore.mdx`)、
  # 止まる直前まで生きていたセッションを SessionStart hook の印から見つけて `claude -r` で開き直す。
  # Needs decision のカードで会話が開いていないものも、最後の対話セッションを開き直して判断待ちを確かめさせる。
  # 中身は home/scripts/agent-resume.sh。
  launchd.agents.agent-resume = {
    enable = true;
    config = {
      # スクリプト実体はリポジトリの絶対パスを直接叩く (worktree-gc.nix と同じ判断)。
      ProgramArguments = [
        "/bin/bash"
        "${dotfilesDir}/home/scripts/agent-resume.sh"
      ];

      # ログイン時に 1 回。Orca がまだ立ち上がっていなければ、スクリプトは何もせずに終わり、次の回で再開する。
      RunAtLoad = true;
      # 3 分ごとに、普通に終わったセッションの印を片付ける。再開が終わるまでの待ちもこの間隔になる。
      StartInterval = 180;

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/agent-resume.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/agent-resume.log";

      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
