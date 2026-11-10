---
name: fix-ci
description: 落ちている CI を調査し、根本原因を修正して green になるまで見届ける。「CIが落ちています 修正してください」の定型フローを1コマンド化。
---

# /fix-ci

## 処理フロー

1. **失敗の特定**
    - `gh pr checks`（PR がない場合は `gh run list --branch <branch>`）で失敗ジョブを特定
    - `gh run view <run-id> --log-failed` で失敗ログを取得する
    - ランが進行中だと `gh run view --log` / `--job <id> --log` はラン全体が終わるまで拒否される（`is still in progress`）。完了したジョブのログは `gh api --allow-escape-sequences repos/<owner>/<repo>/actions/jobs/<job-id>/logs > job.log` で先に取れる（`--allow-escape-sequences` が無いと出力を拒否する）。job id は `gh run view <run-id> --json jobs --jq '.jobs[] | {name, databaseId, conclusion}'` で引く

2. **根本原因の診断**
    - ログの**最初の実エラー**を特定する（後続のカスケード失敗と区別する）
    - 可能ならローカルで再現する（CI と同じテスト・lint・ビルドコマンドを実行）
    - **flaky（再実行で通る・インフラ起因）か本物か**を区別し、判断根拠を添えて報告する
    - flaky と判断した場合は勝手に再実行せず、根拠を示してユーザーに確認する

3. **修正と確認**
    - 根本原因を修正する。テストの skip・lint の suppress・baseline 追加など「黙らせる」対応はしない
    - `/commit` と同じ規約でコミットする
    - PR 本文に検証の skill が書いた節（例: `## ローカル実機確認`）があれば、**push の前に**その先頭へ「この証拠は `<push 前の PR の head の SHA>` までのもの。以後は未再検証」と 1 行足す（SHA と本文は `gh pr view --json headRefOid,body`、書き戻しは `gh pr edit --body-file`）。push の後に書くと、途中で止まったとき古い証拠がそのまま残る。すでにその行があれば書き換えない（新しい SHA にすると、証拠の範囲を広げてしまう）
    - push する
    - `gh pr checks --watch` で green になるまで見届け、結果を報告する

## 注意事項

- ユーザーへの確認は、文章の質問で終わらせず AskUserQuestion で聞く（無い環境では、Orca の worktree ならカードを Needs decision に移してから聞く）。自動で起動されたときは人が見ておらず、文章の質問は誰にも届かない。答えが来るまで push しない
- CI 設定（workflow yaml）側に原因がある場合は、その旨を先に報告してから修正する
- 修正がスコープ外へ膨らむ場合（依存更新が必要になる等）は、着手前にユーザーへ確認する
- ログに秘匿情報（トークン等）が含まれていても出力に転記しない
