# GitHub に投稿するコメント・レビュー

- PR に投稿するコメント・レビューには、生成元表記（`🤖 Generated with [Claude Code]`）もリアクション依頼（`If this code review was useful, please react with 👍...`）も付けない。
  `### Code review` / `Found N issues:` のような見出し・前置きも不要。指摘そのものだけを書く
- `/code-review` 系の skill のテンプレートはそのまま使わず、フッターと見出しを落とす
- 指摘が特定の行に紐づくなら、review の本文ではなく**インラインコメント**として最初から出す
  （`POST /repos/{owner}/{repo}/pulls/{n}/reviews` に `comments[]` を渡す）。review の本文は空でよい（`PUT .../reviews/{id}` に `body=''` で空にできる）
- インラインコメントは diff に含まれる行にしかアンカーできない。変更外のファイルへの指摘は diff 内の関連行に付け、本文から head SHA のパーマリンクで参照する

**Why:** `/code-review` skill のテンプレートには定型のフッターが含まれているが、ユーザーはこれをノイズと見なしている。skill の出力形式より本人の指示が優先する。
