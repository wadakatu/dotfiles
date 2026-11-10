---
name: sync-pr
description: PR ブランチを base の最新に rebase で追従させ、conflict を解消して push する。「conflictを解消してください」「最新化してください」の定型フローを1コマンド化。
---

# /sync-pr

## 処理フロー

1. **状態確認**
    - `git branch --show-current` と `gh pr view --json baseRefName,state` で対象ブランチと base を確認
    - 作業ツリーが dirty なら停止して報告する（勝手に stash しない）
    - ブランチに自分以外のコミットが含まれる場合は、rebase してよいか先にユーザーへ確認する

2. **rebase による最新化**
    - `git fetch origin` → `git rebase origin/<base>`
    - conflict は**各箇所の変更意図を確認して**解消する。機械的に ours / theirs を採らない
    - 双方の変更意図が本質的に衝突している場合は、解消案を提示してユーザーに確認する
    - 想定外の状態になったら `git rebase --abort` で戻し、状況を報告する

3. **検証と push**
    - 変更に関係するテスト・lint を実行して壊れていないことを確認する
    - PR 本文に検証の skill が書いた節（例: `## ローカル実機確認`）があれば、**push の前に**その先頭へ「この証拠は `<push 前の PR の head の SHA>` までのもの。以後は未再検証」と 1 行足す（SHA と本文は `gh pr view --json headRefOid,body`、書き戻しは `gh pr edit --body-file`）。push の後に書くと、途中で止まったとき古い証拠がそのまま残る。すでにその行があれば書き換えない（新しい SHA にすると、証拠の範囲を広げてしまう）
    - `git push --force-with-lease` で更新する（rebase 後の push はこれを既定とする。`--force` は使わない）

## 注意事項

- ユーザーへの確認は、文章の質問で終わらせず AskUserQuestion で聞く（無い環境では、Orca の worktree ならカードを Needs decision に移してから聞く）。自動で起動されたときは人が見ておらず、文章の質問は誰にも届かない。答えが来るまで push しない
- rebase 中にコミット内容そのものを書き換えない（conflict 解消に必要な最小変更のみ）
- conflict 解消で新たな修正が必要になった場合は、rebase 完了後に別コミットとして積む
