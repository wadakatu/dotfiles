{ config, dotfilesDir, ... }: {
  # 自分の OPEN な PR を数分ごとに見て、conflict / CI 失敗 / 未対応のレビューがあれば
  # Orca のタブでエージェントを起動する LaunchAgent。対象は Orca に worktree がある非 draft の PR。
  # あわせて、人の判断待ち (マージ判断、自動対応の上限超え、入力待ちや質問で止まったエージェント) を
  # Orca のボードに出す。PR がマージ・クローズされた worktree のカードは、worktree-gc が消すまで Done に置く。
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

      # 3 分ごと。人の判断待ちをボードに出す役も兼ねるので、30 分では遅すぎた。
      # 1 回の GitHub 問い合わせは GraphQL 1〜2 ポイントで、上限 (1 時間 5,000) に対して十分小さい。
      # スリープ中と、前の回がまだ走っているときの起動は飛ばされる (man launchd.plist の StartInterval)。
      StartInterval = 180;

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pr-dispatch.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pr-dispatch.log";

      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
