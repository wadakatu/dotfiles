{ config, pkgs, dotfilesDir, ... }:
let
  # 作業ツリーのスクリプトは直接叩かない。dotfiles の checkout でブランチ作業をしていると、
  # レビュー前のスクリプトが無人で動いてしまう。毎回 origin/main の home/scripts を取り出し、その写しを実行する。
  # (prompt と schema はスクリプトと同じディレクトリから読まれるので、ディレクトリごと取り出す)
  launcher = pkgs.writeShellScript "memory-maintenance-launcher" ''
    set -euo pipefail
    dir="$HOME/Library/Caches/memory-maintenance-script"
    git -C "$DOTFILES_DIR" fetch --quiet origin main ||
      echo "WARN: dotfiles の fetch に失敗。手元の origin/main で続ける" >&2
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$DOTFILES_DIR" archive origin/main home/scripts | tar -x -C "$dir"
    exec /bin/bash "$dir/home/scripts/memory-maintenance.sh" "$@"
  '';
in
{
  # Claude Code の auto memory (~/.claude/projects/*/memory) と共有メモリ (~/.claude-shared-memory) を
  # 毎日整理する LaunchAgent。設計は docs/memory-maintenance-design.md。
  #
  # pr-dispatch / worktree-gc と同じく、判定 (何が変わったか、ガード、PR の状態) はスクリプトで決め、
  # AI (claude -p --restricted) は変化のあったメモリを分類・編集するときだけ起動する。
  # 削除・移動・git・push・PR はスクリプトが行い、AI には作業領域の読み取りと memory の写しの編集しか渡さない。
  launchd.agents.memory-maintenance = {
    enable = true;
    config = {
      # スクリプトの変更はマージだけで次の実行から効く (pull も rebuild も要らない)。
      ProgramArguments = [ "${launcher}" ];

      # 毎日 04:30。対話セッションと重なりにくい時間にする (重なっても、保守の間に変わったファイルは写さずに翌日へ回す)。
      # スリープ中に跨いだ分は起床後にまとめて 1 回実行される (launchd の仕様)。
      StartCalendarInterval = [
        { Hour = 4; Minute = 30; }
      ];

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/memory-maintenance.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/memory-maintenance.log";

      # claude は ~/.local/bin にある (公式インストーラの場所)。
      EnvironmentVariables = {
        # クローン先はマシンごとに違う (flake.nix の mkDarwin)。スクリプトの既定値ではなくこれを使う。
        DOTFILES_DIR = dotfilesDir;
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:${config.home.homeDirectory}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
