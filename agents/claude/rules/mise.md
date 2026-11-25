# mise の shim と作業ディレクトリ

- Bash ツールの PATH は SessionStart hook（`hooks/mise-shims-first.sh`）で mise の installs よりシムが前になり、コマンドごとにカレントの `mise.toml` で版が決まる（無ければグローバル版）。`which <tool>` はシムを指すので、実体は `mise which <tool>` で見る。
- `command -v <tool>` が `installs/` を指すなら hook が入っていない（`~/.claude` への配置は手作業）。`~/.local/share/mise/shims/<tool>` を明示するか、PATH の先頭に shims を足す。
- 起動したシェルが installs より前に置いた bin（`nix develop` / `devenv`）はそのまま優先される。
- 新しい worktree では先に `mise trust`。
- scratch で版を試すなら `[tools]` の `mise.toml` を置いて `mise trust` する。
- 実行前に `<tool> --version`、実行後は出力で版を確かめる。
- 移動先の `[env]` はシム経由で起動したプロセスにしか入らない。起動ディレクトリの `[env]` は Claude が受け継いでいて、`cd` した後もシムを通らないコマンド（`printenv` など）に残る。

**Why:** Bash ツールは Claude プロセスの PATH を使い回し、起動したシェルの `mise activate` が入れた起動ディレクトリの版が先頭に固定されていた。起動時の pnpm 9 を 12 と取り違え、`--no-frozen-lockfile` で lockfile を書き換えかねなかった。
