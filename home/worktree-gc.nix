{ config, ... }: {
  # work-api の worktree と、それに紐づく docker compose プロジェクトを
  # 1 日 2 回掃除する LaunchAgent。放置すると worktree ごとに nginx/php-fpm/redis の
  # 3 コンテナと bridge network が積み上がり、docker のサブネットプールが枯れて
  # `make up` が落ちる (実測: worktree 20 個でコンテナ 102 個・ネットワーク 26 個)。
  #
  # AI エージェントではなくスクリプトで回すのは、判定が全て機械的に決まるため。
  # 「upstream が remote から消えた」「origin/dev から辿れる」「未コミットが無い」
  # 以外の材料を使わないので、モデルに投げる理由が無い。
  launchd.agents.worktree-gc = {
    enable = true;
    config = {
      # スクリプト実体は /nix/store に焼かず、リポジトリの絶対パスを直接叩く。
      # herdr.nix と同じ判断で、閾値や除外を触るたびに darwin-rebuild を回したくないため。
      # 実行ビットはリポジトリ側で立てておくこと (chmod +x)。
      ProgramArguments = [
        "/bin/bash"
        "${config.home.homeDirectory}/www/dotfiles/home/scripts/worktree-gc.sh"
      ];

      # 12:00 と 21:00。スリープ中に跨いだ分は起床後にまとめて 1 回実行される
      # (launchd の仕様。掃除用途なので取りこぼしても次の回で拾える)。
      StartCalendarInterval = [
        { Hour = 12; Minute = 0; }
        { Hour = 21; Minute = 0; }
      ];

      # 無人で消す以上、何を消したかが後から読めることが唯一の歯止めになる。
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/worktree-gc.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/worktree-gc.log";

      # launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin しか無く、docker も
      # nix の git も解決できない。スクリプト側でも PATH を上書きしているが、
      # ここにも置いて「PATH が理由で黙って何もしない」状態を二重に防ぐ。
      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
