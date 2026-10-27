{ ... }:
let
  base = ../agents/codex/config.toml;
in
# 評価時に TOML として parse できることを確かめる。壊れていれば nix flake check (CI) で落ちる。
assert builtins.isAttrs (builtins.fromTOML (builtins.readFile base));
{
  # Codex の system 層 (/etc/codex/config.toml)。environment.etc は nix-darwin のシステムモジュールで、
  # /etc/<name> -> /etc/static/<name> -> /nix/store/... の読み取り専用リンクを root の activation が張る。
  # 手で書いた設定だけを置き、Codex が自分で書く状態は ~/.codex/config.toml (user 層) に残す (README「Codex の設定」)。
  environment.etc."codex/config.toml".source = base;

  # branch-guard を system 層の hook にする。system 層の hook は managed 扱いで /hooks の trust が要らず、
  # /hooks から無効化もできない (codex-rs hooks/src/engine/discovery.rs)。新しい Mac でも初回から効く。
  # スクリプトは store にコピーして固定する。作業ツリーを指すと、未コミットの編集や移動がそのまま
  # 全ユーザー向けの trusted hook に入るため。branch-guard を直したら rebuild で反映する。
  environment.etc."codex/hooks.json".text = builtins.toJSON {
    hooks.PreToolUse = [{
      matcher = "Bash";
      # 実行ビットに頼らないよう sh で起動する。
      hooks = [{ type = "command"; command = "/bin/sh ${../agents/claude/hooks/branch-guard.sh}"; }];
    }];
  };
}
