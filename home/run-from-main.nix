# LaunchAgent が home/scripts/<name>.sh を動かすための起動スクリプトを作る (module ではなく関数)。
#   launcher = import ./run-from-main.nix { inherit pkgs dotfilesDir; } "<name>";
#
# 作業ツリーのスクリプトは直接叩かない。dotfiles の checkout でブランチ作業をしていると、
# レビュー前のスクリプトが無人で動いてしまう。origin/main の home/scripts を取り出し、その写しを実行する。
# スクリプトの変更はマージだけで次の実行から効く (pull も rebuild も要らない)。
{ pkgs, dotfilesDir }:
name:
pkgs.writeShellScript "${name}-launcher" ''
  set -euo pipefail
  repo=${pkgs.lib.escapeShellArg dotfilesDir}
  # 取り出し先は LaunchAgent ごとに分ける。同じ LaunchAgent の実行は重ならないが、別の LaunchAgent とは重なる。
  # (agent-resume は自分のパスを Orca のタブに渡して後から起動させるので、他の LaunchAgent に消されると困る)
  dir="$HOME/Library/Caches/${name}-script"
  # fetch は 15 分に 1 回まで。3 分ごとの LaunchAgent が毎回 GitHub に問い合わせないようにする。
  if [ -z "$(find "$repo/.git/FETCH_HEAD" -mmin -15 2>/dev/null)" ]; then
    git -C "$repo" fetch --quiet origin main ||
      echo "WARN: dotfiles の fetch に失敗。手元の origin/main で続ける" >&2
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  # prompt や schema はスクリプトと同じディレクトリから読まれるので、ディレクトリごと取り出す。
  git -C "$repo" archive origin/main home/scripts | tar -x -C "$dir"
  exec /bin/bash "$dir/home/scripts/${name}.sh" "$@"
''
