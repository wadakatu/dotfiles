---
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
    - `git push --force-with-lease` で更新する（rebase 後の push はこれを既定とする。`--force` は使わない）

## 注意事項

- rebase 中にコミット内容そのものを書き換えない（conflict 解消に必要な最小変更のみ）
- conflict 解消で新たな修正が必要になった場合は、rebase 完了後に別コミットとして積む
