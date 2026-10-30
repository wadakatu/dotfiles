{ config, dotfilesDir, ... }: {
  # Claude Code の auto memory (~/.claude/projects/*/memory) と共有メモリ (~/.claude-shared-memory) を
  # 毎日整理する LaunchAgent。設計は docs/memory-maintenance-design.md。
  #
  # pr-dispatch / worktree-gc と同じく、判定 (何が変わったか、ガード、PR の状態) はスクリプトで決め、
  # AI (claude -p --restricted) は変化のあったメモリを分類・編集するときだけ起動する。
  # 削除・移動・git・push・PR はスクリプトが行い、AI には作業領域の読み取りと memory の写しの編集しか渡さない。
  launchd.agents.memory-maintenance = {
    enable = true;
    config = {
      # スクリプト実体はリポジトリの絶対パスを直接叩く (worktree-gc.nix と同じ判断)。
      ProgramArguments = [
        "/bin/bash"
        "${dotfilesDir}/home/scripts/memory-maintenance.sh"
      ];

      # 毎日 04:30。対話セッションと重なりにくい時間にする (重なっても、保守の間に変わったファイルは写さずに翌日へ回す)。
      # スリープ中に跨いだ分は起床後にまとめて 1 回実行される (launchd の仕様)。
      StartCalendarInterval = [
        { Hour = 4; Minute = 30; }
      ];

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/memory-maintenance.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/memory-maintenance.log";

      # claude は ~/.local/bin にある (公式インストーラの場所)。
      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:${config.home.homeDirectory}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
