# mise の shim と作業ディレクトリ

- mise の shim（`~/.local/share/mise/shims/<tool>`）は、カレントディレクトリの `mise.toml` で版を解決する。
  scratchpad など `mise.toml` の無い場所で動かすと、リポジトリの pin ではなくグローバル版が動く。
- ツールの版による違いを scratch ディレクトリで確かめるときは、そこにも `[tools]` の `mise.toml` を置いて `mise trust` する。
- 実際に動いた版を出力で確かめる。pnpm なら末尾の `Done in Xms using pnpm v<version>` 行。エラー書式でも見分けられる（` ERROR  Unknown options:` は TypeScript 版の pnpm 11 以前、`error: unexpected argument` は Rust 版の pnpm 12）。

**Why:** グローバル版で動いたことに気付かず、古い版の挙動を新しい版の挙動として報告したことがある（pnpm 9 が lockfile に `libc:` を書かないのを、pnpm 12 が落とすと取り違えた）。

## Bash ツールの PATH は起動ディレクトリの版で固定される

- Claude Code の Bash は、セッションを起動したディレクトリで `mise activate` 済みの PATH を持つ。PATH の先頭に `~/.local/share/mise/installs/<tool>/<起動時の版>` が直接入るので、別の worktree やリポジトリに `cd` しても、その `mise.toml` の pin（`mise current` には出る）ではなく起動時の版が動く。`mise trust` しても変わらない。
- 起動ディレクトリと違うリポジトリでツールを動かすときは、`~/.local/share/mise/shims/<tool>` を明示するか、`export PATH=$HOME/.local/share/mise/shims:$PATH` を前に付ける。`<tool> --version` で版を確かめてから実行する。新しい worktree では先に `mise trust`。

**Why:** pin が pnpm 12 のリポジトリで起動時の pnpm 9 が動き、`pnpm install --frozen-lockfile` が `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH` で止まった。lockfile の不一致を「リポジトリ側の不整合」と誤読しやすく、`--no-frozen-lockfile` で lockfile を書き換える事故につながる。
