{ config, pkgs, dotfilesDir, ... }: {
  # 放置された Claude / Codex のセッションを 10 分ごとに見つけて通知する LaunchAgent。巡回は origin/main の写しを動かす。
  # 止めるのは、ユーザーが `agent-gc stop` (checkout の版) を打ったときと、~/.config/worktree-gc.env の
  # RULE_session_autostop=on の巡回で、どちらも Orca の端末に /exit を送る。規則の切り替えに rebuild は要らない。
  # 中身は home/scripts/agent-gc.sh、設計は docs/agent-gc-design.md。
  launchd.agents.agent-gc = {
    enable = true;
    config = {
      # 作業ツリーではなく、origin/main から取り出したスクリプトの写しを動かす (run-from-main.nix。worktree-gc.nix と同じ)。
      # checkout がレビュー前のブランチに居ても、その版は無人で動かない。閾値を変えても、マージすれば次の実行から効く。
      # --auto は LaunchAgent からの巡回の印。送る・台帳に書くのは --auto の付いた scan だけ (手で打つ scan は would stop まで)。
      ProgramArguments = [ "${import ./run-from-main.nix { inherit pkgs dotfilesDir; } "agent-gc"}" "scan" "--auto" ];

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
