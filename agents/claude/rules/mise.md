# mise の shim と作業ディレクトリ

- shim はカレントの `mise.toml` で版を決め（無ければグローバル版）、Bash の PATH には起動ディレクトリの版が先に入る（`cd` や `mise trust` では変わらない）。
- 起動ディレクトリと違うリポでは `~/.local/share/mise/shims/<tool>` を明示するか、PATH の先頭に shims を足す。新しい worktree では先に `mise trust`。
- scratch で版を試すなら `[tools]` の `mise.toml` を置いて `mise trust` する。
- 実行前に `<tool> --version`、実行後は出力で版を確かめる。

**Why:** 起動時の pnpm 9 を 12 と取り違え、`--no-frozen-lockfile` で lockfile を書き換えかねなかった。
