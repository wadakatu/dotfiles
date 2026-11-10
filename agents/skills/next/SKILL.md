---
name: next
description: 現在の PR の状態を確認し、計画中の次のタスクへ進む。マージ済みなら default ブランチを同期して進み、マージ前でも次のタスクがその PR に依存しなければ待たずに始める。「PRをマージしました 次に進んでください」「次に進んでください」の定型フローを1コマンド化。
---

# /next

PR の状態確認 → （マージ済みなら）default ブランチ同期 → 次タスク着手、のキュー進行を行う。
マージを待つのは、次のタスクがマージ前の PR に依存するときだけ。

## 処理フロー

1. **現在の PR の状態確認**
    - `git branch --show-current` で現ブランチを確認
    - `gh pr view --json number,state,mergedAt,url` で現ブランチの PR の状態を確認
    - マージ済み → 手順 2 へ
    - open → 手順 2 は飛ばして手順 3 へ（この PR・ブランチ・カードには触らない）
    - マージされずに閉じられている → **ここで停止**し、状況を報告する
    - 現ブランチに PR がない場合（すでに default ブランチ上にいる等）は手順 3 へ進む

2. **default ブランチの同期とローカル掃除**（PR がマージ済みのときだけ）
    - **Orca が管理する worktree にいるとき**（`orca worktree current --json` が `"ok": true` で `isMainWorktree` が false）:
        - switch・pull・ブランチ削除はしない（default ブランチは main checkout で使用中なので worktree では switch できない）
        - `orca worktree set --worktree current --workspace-status completed --comment "merged #<番号>" --json` でボードを Done にする
        - この worktree 自体は消さない（自分のタブごと閉じるため）。worktree-gc が削除条件を確かめて消す
    - それ以外（main checkout や Orca 外）:
        - default ブランチ（`gh repo view --json defaultBranchRef` で確認）へ switch → `git pull --ff-only`
        - マージ済みの作業ブランチを `git branch -d` で削除する（`-D` は使わない。削除できない場合は理由を報告して残す）

3. **次タスクの特定**
    - 次タスクは以下の優先順で特定する:
        1. 会話中で合意済みの計画・タスクリストの次項目
        2. エピック issue / tracking issue のチェックリストの未完了項目
        3. ユーザーの直前の指示
    - すでに誰かが着手している項目は飛ばす。open の PR がある項目（issue なら `gh issue view <N> --json closedByPullRequestsReferences`、それ以外は `gh pr list --state open` の題名とブランチ名）と、worktree が既にある項目（`git worktree list`、Orca なら `orca worktree list --json`）
    - 候補が複数ある・特定できない場合は、候補を並べてユーザーに確認する（勝手に選ばない）

4. **マージ前の PR に依存するかの判定**（この計画の PR で、まだマージされていないものがあるときだけ）
    - 次のどれかに当たれば「依存する」:
        - マージ前の PR が足した・変えたもの（関数・型・スキーマ・migration・設定・生成物）を、次のタスクが使う
        - マージ前の PR と同じファイルの同じ箇所を触る見込みがある（`gh pr diff <番号> --name-only` と次のタスクの対象を突き合わせる）
        - 計画や issue に順序が書かれている（「〜の後」、issue の `blockedBy`、チェックリストの前提）
    - 依存する、または判定できない → **ここで停止**し、待っている PR の現状（open / CI / レビュー状態）を簡潔に報告する。マージ前の PR のブランチから次のブランチを切って進めることはしない
    - 依存しない → 根拠を 1 行で示して手順 5 へ

5. **着手**
    - **「次: 〜」と簡潔に提示してから**着手する。マージ前の PR を残して進むときは、その URL も 1 行で示す（マージは人が押す）
    - 次のタスクは default ブランチの最新から始める。マージ前の PR のブランチからは切らない
        - Orca の worktree にいたとき: `orca worktree create` で作る新しい worktree で始める（この worktree では続けない）。元の worktree はそのまま残す（残った PR の CI・レビュー・conflict への対応は、その worktree で行われる）
        - それ以外: `git fetch origin` のあと `git switch -c <新しいブランチ> origin/<default ブランチ>`。未コミットの変更が残っていたら止まって報告する。マージ前の PR のブランチは消さない
    - 以降は通常のフロー（実装 → 検証 → `/pr`）に従う

## 注意事項

- 依存の判定を省略しない。依存するタスクをマージ前に始めると、後続 PR の base が混線し、前の PR がレビューで変わったときに作り直しになる
- 迷ったら「依存する」として止まる。待たずに進めてよいのは、依存しない根拠を示せるときだけ
- squash merge の場合 `git branch -d` が拒否されることがある。その場合はリモート追跡が消えている（マージ済みの）ことを `gh pr view` で確認したうえで削除してよい
