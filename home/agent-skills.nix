{ config, lib, dotfilesDir, ... }:
let
  # agents/ 配下の skill を、各エージェントが読む場所へ 1 つずつ symlink する。
  #   agents/skills/         Claude Code と Codex の両方 (~/.claude/skills と ~/.agents/skills)
  #   agents/claude/skills/  Claude Code だけ
  #   agents/codex/skills/   Codex だけ (Codex の個人用 skill の場所は ~/.agents/skills)
  # ~/.claude/skills はディレクトリごとは管理しない。synced (claude.ai から同期した skill の予約名) と
  # Orca が入れる orca-cli が同じ場所に置かれるため。
  #
  # mkOutOfStoreSymlink で作業ツリーの実体を直接指す (herdr.nix と同じ)。書き込みもでき、
  # skill を直したら rebuild なしで両方に効く。skill を足したときだけ rebuild が要る。
  # 名前の一覧は flake source 側のコピー (相対パス) から読む。dotfilesDir の絶対パスは
  # 純粋な評価では読めないので、リンク先にだけ使う。
  skillNames = dir:
    builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir));

  linkSkills = target: src: dir:
    lib.listToAttrs (map
      (name: lib.nameValuePair "${target}/${name}" {
        source = config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/agents/${src}/${name}";
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
    # 定義を足しても rebuild は要らない (/agents で作った定義もリポジトリ側に入る)。
    // {
      ".claude/agents".source =
        config.lib.file.mkOutOfStoreSymlink "${dotfilesDir}/agents/claude/agents";
    };
}
