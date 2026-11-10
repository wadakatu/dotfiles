# LaunchAgent が home/scripts/<name>.sh を動かすための起動スクリプトを作る (module ではなく関数)。
#   launcher = import ./run-from-main.nix { inherit pkgs dotfilesDir; } "<name>";
#
# 作業ツリーのスクリプトは直接叩かない。dotfiles の checkout でブランチ作業をしていると、
# レビュー前のスクリプトが無人で動いてしまう。origin/main の写し (scripts/live-sync.sh が作る) を実行する。
# スクリプトの変更はマージだけで次の実行から効く (pull も rebuild も要らない)。
# 写しは skill・rule (agent-skills.nix) と共通で、置き場所はそちらと揃える。
{ pkgs, dotfilesDir }:
name:
pkgs.writeShellScript "${name}-launcher" ''
  set -euo pipefail
  live="$HOME/.local/share/dotfiles-live"
  # 写しを作れなくても (origin/main が読めない、ディスクが一杯)、前に作った版があればそれで動かす。
  dir=$(/bin/bash ${./scripts/live-sync.sh} ${pkgs.lib.escapeShellArg dotfilesDir} "$live") || dir="$live/current"
  # prompt や schema はスクリプトと同じディレクトリから読まれる。
  exec /bin/bash "$dir/home/scripts/${name}.sh" "$@"
''
