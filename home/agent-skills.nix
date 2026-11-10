{ config, lib, pkgs, dotfilesDir, ... }:
let
  # origin/main から取り出した写し (scripts/live-sync.sh が作る)。current は最新の版への symlink。
  # LaunchAgent のスクリプト (run-from-main.nix) と共通。
  live = "${config.home.homeDirectory}/.local/share/dotfiles-live";

  # agents/ 配下の skill を、各エージェントが読む場所へ 1 つずつ symlink する。
  #   agents/skills/         Claude Code と Codex の両方 (~/.claude/skills と ~/.agents/skills)
  #   agents/claude/skills/  Claude Code だけ
  #   agents/codex/skills/   Codex だけ (Codex の個人用 skill の場所は ~/.agents/skills)
  # ~/.claude/skills はディレクトリごとは管理しない。synced (claude.ai から同期した skill の予約名) と
  # Orca が入れる orca-cli が同じ場所に置かれるため。
  #
  # リンク先は作業ツリーではなく main の写し。作業ツリーを指していたときは、checkout が別のブランチに居る間、
  # main に入れた skill と rule が効かなかった (逆に、レビュー前の変更が全セッションに効いた)。
  # 写しは読み取り専用で、その場では直せない。skill を直したら、マージすれば rebuild なしで効く
  # (LaunchAgent が 15 分に 1 回 fetch して current を進める)。skill を足したり消したりしたときだけ rebuild が要る。
  # 名前の一覧は flake source 側のコピー (相対パス) から読む。
  skillNames = dir:
    builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir));

  linkSkills = target: src: dir:
    lib.listToAttrs (map
      (name: lib.nameValuePair "${target}/${name}" {
        source = config.lib.file.mkOutOfStoreSymlink "${live}/current/agents/${src}/${name}";
      })
      (skillNames dir));
in
{
  home.file =
    linkSkills ".claude/skills" "skills" ../agents/skills
    // linkSkills ".agents/skills" "skills" ../agents/skills
    // linkSkills ".claude/skills" "claude/skills" ../agents/claude/skills
    // linkSkills ".agents/skills" "codex/skills" ../agents/codex/skills
    # Claude Code のエージェント定義はディレクトリごと張る。ここには他のツールが自分のファイルを置かないので、
    # 定義を足しても rebuild は要らない。読み取り専用なので /agents では作れない (リポジトリに置いて PR にする)。
    // {
      ".claude/agents".source =
        config.lib.file.mkOutOfStoreSymlink "${live}/current/agents/claude/agents";
      # user スコープの rules。毎セッション読まれる。auto memory からのグローバル昇格の受け皿
      # (home/scripts/memory-maintenance.sh が PR にする)。rules を足しても rebuild は要らない。
      ".claude/rules".source =
        config.lib.file.mkOutOfStoreSymlink "${live}/current/agents/claude/rules";
      # Codex のグローバル指示。これだけは作業ツリーを指す (~/.claude/CLAUDE.md が手動コピーなのと同じ扱い)。
      # Codex が AGENTS.md を書くのは他エージェントからの取り込み
      # (external-agent-migration の import_agents_md) だけで、空でないファイルには書かない。
      ".codex/AGENTS.md".source =
        config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/agents/codex/AGENTS.md";
    };

  # rebuild の時点で写しを用意する。無いと、LaunchAgent の最初の実行までリンクが宙に浮く。
  # ここでは fetch しない (activation をネットワークで止めない)。手元の origin/main が古ければ、
  # LaunchAgent の次の実行で進む。
  # activation の PATH は Home Manager が絞るので、スクリプトが使うコマンドを渡す。
  home.activation.dotfilesLive = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run --quiet ${pkgs.coreutils}/bin/env PATH=${lib.makeBinPath [ pkgs.git pkgs.gnutar pkgs.coreutils pkgs.findutils ]} LIVE_SYNC_NO_FETCH=1 \
      /bin/bash ${./scripts/live-sync.sh} ${lib.escapeShellArg dotfilesDir} ${lib.escapeShellArg live} ||
      echo "WARN: dotfiles の写しを作れなかった。skill と rule は LaunchAgent の次の実行まで読めない" >&2
  '';
}
