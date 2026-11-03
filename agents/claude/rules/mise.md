# mise の shim と作業ディレクトリ

- mise の shim（`~/.local/share/mise/shims/<tool>`）は、カレントディレクトリの `mise.toml` で版を解決する。
  scratchpad など `mise.toml` の無い場所で動かすと、リポジトリの pin ではなくグローバル版が動く。
- ツールの版による違いを scratch ディレクトリで確かめるときは、そこにも `[tools]` の `mise.toml` を置いて `mise trust` する。
- 実際に動いた版を出力で確かめる。pnpm なら末尾の `Done in Xms using pnpm v<version>` 行。エラー書式でも見分けられる（` ERROR  Unknown options:` は TypeScript 版の pnpm 11 以前、`error: unexpected argument` は Rust 版の pnpm 12）。

**Why:** グローバル版で動いたことに気付かず、古い版の挙動を新しい版の挙動として報告したことがある（pnpm 9 が lockfile に `libc:` を書かないのを、pnpm 12 が落とすと取り違えた）。
