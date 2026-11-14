# セッションの外のリポジトリにコミットする

- cwd と別のリポジトリ（ユーザーも作業中のもの）へのコミットは、`git worktree add <scratchpad>/wt/<name> <branch>` の隔離した作業ツリーで add / commit / push し、終わったら `git worktree remove`。ユーザーのチェックアウトとブランチには触れない。
- 隔離できないときも、各コミットの直前に `git -C <dir> branch --show-current` を確かめる。
- 別リポジトリの git 操作は `git -C <絶対パス> …` で書く（branch-guard はセッションの cwd で判定し、`cd` は一部の形しか読まない）。

**Why:** コミットの間にユーザーがブランチを切り替え、他人のブランチに push された。
