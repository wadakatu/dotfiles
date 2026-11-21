# linked worktree での依存の install と git hooks

- `git worktree add` した作業ツリーで `pnpm install` などを流す前に、`package.json` の `prepare` / `postinstall` を読む。hooks と local の git 設定は worktree ごとでなく共有の `.git` にあるので、git hooks の導入（`lefthook install`、`husky`、`git config --unset-all core.hooksPath` など）は主 checkout にも効く。
- 触るものなら、先に `git -C <主 checkout> config --local --get core.hooksPath` と `ls <主 checkout>/.git/hooks` を記録してから流すか、`--ignore-scripts` で install して要るスクリプトだけ手で流す。
- サブエージェントに install を任せるときも、これを依頼文に書く。

**Why:** ユーザーも作業中のリポジトリから切った隔離 worktree で install したら、`prepare` が共有の `.git` の `core.hooksPath` を外し、hooks を入れ直した。作業ツリーとブランチは無事だったが、「ユーザーの checkout に触れない」前提が破れ、実行前の状態も残していなかった。
