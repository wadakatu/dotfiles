{ config, pkgs, dotfilesDir, ... }: {
  # 自分の OPEN な PR を数分ごとに見て、conflict / CI 失敗 / 未対応のレビューがあれば
  # Orca のタブでエージェントを起動する LaunchAgent。対象は Orca に worktree がある非 draft の PR。
  # あわせて、人の判断待ち (自動対応の上限超え、入力待ちや質問で止まったエージェント) を
  # Orca のボードに出す。マージできる PR のカードは In review に置いて未読と「マージ可」を付け、
  # PR がマージ・クローズされた worktree のカードは、worktree-gc が消すまで Done に置く。
  # 毎回の最初に、Mac の再起動で止まった Claude のセッションの再開 (home/scripts/agent-resume.sh) も行う。
  # 再開と PR 対応を 1 つの LaunchAgent にまとめたのは、同じ worktree に両方のエージェントを並べないため
  # (再開を先に済ませ、再開したセッションに指示が入るまで、その worktree への PR 対応を待つ)。
  #
  # 判定をスクリプトで回すのは worktree-gc と同じ理由で、材料 (mergeable、CI の結果、
  # 未解決スレッドの最後の発言者) が機械的に決まるため。AI は対応が要るときだけ起動する。
  launchd.agents.pr-dispatch = {
    enable = true;
    config = {
      # origin/main から取り出したスクリプトの写しを動かす (worktree-gc.nix と同じ)。
      ProgramArguments = [ "${import ./run-from-main.nix { inherit pkgs dotfilesDir; } "pr-dispatch"}" ];

      # ログイン時に 1 回 (再起動で止まったセッションの再開)。Orca がまだ立ち上がっていなければ、
      # スクリプトは何もせずに終わり、次の回で再開する。
      RunAtLoad = true;
      # 3 分ごと。人の判断待ちをボードに出す役も兼ねるので、30 分では遅すぎた。
      # 1 回の GitHub 問い合わせは GraphQL 1〜2 ポイントで、上限 (1 時間 5,000) に対して十分小さい。
      # スリープ中と、前の回がまだ走っているときの起動は飛ばされる (man launchd.plist の StartInterval)。
      StartInterval = 180;

      # AbandonProcessGroup は付けない (既定は false)。スクリプトが落ちたときに、呼び出し中の agent-resume.sh を
      # launchd に片付けさせる。残ると、次の回がロックを回収して並んで動く (home/scripts/pr-dispatch.sh の「再開」の節)。
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pr-dispatch.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pr-dispatch.log";

      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
