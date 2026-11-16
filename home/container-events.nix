{ config, pkgs, dotfilesDir, ... }: {
  # 手元の設定 (~/.config/container-events.env) で指定したコンテナの die / oom を、落ちたその場で記録し続ける LaunchAgent。
  # Docker は起動し直すたびに終了コードと OOMKilled を戻し、VM のカーネルログも次のメモリ不足で上書きされる。
  # docker events は過去の時間帯を引き直しても返らないので、後から調べる手段が無い。中身は home/scripts/container-events.sh。
  launchd.agents.container-events = {
    enable = true;
    config = {
      # origin/main から取り出したスクリプトの写しを動かす (worktree-gc.nix と同じ)。
      # 常駐なので、マージした変更は次に起動し直したときから効く。
      ProgramArguments = [ "${import ./run-from-main.nix { inherit pkgs dotfilesDir; } "container-events"}" ];

      # docker events が切れた・Docker に繋がらない (0 以外で終わる) ときだけ起こし直す。SuccessfulExit は RunAtLoad も兼ねる。
      # 対象のコンテナが未設定なら 0 で終わり、起こし直さない (設定の無い Mac で毎分起動し続けないように)。
      # 設定を書いたら launchctl kickstart で起こす (README)。
      KeepAlive = { SuccessfulExit = false; };
      # Docker が止まっている間、起動と終了を高速で繰り返さないよう間を空ける (既定は 10 秒)。
      ThrottleInterval = 60;

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/container-events.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/container-events.log";

      # launchd の PATH には docker も jq も無い (worktree-gc.nix と同じ)。
      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
