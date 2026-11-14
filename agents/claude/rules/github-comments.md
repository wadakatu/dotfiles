# GitHub に投稿するコメント・レビュー

- PR のコメント・レビューに生成元表記・リアクション依頼・見出し（`### Code review` `Found N issues:`）を付けず、指摘だけを書く。`/code-review` 系 skill のテンプレートでも落とす。
- 行への指摘は最初からインラインで出す（`POST .../pulls/{n}/reviews` の `comments[]`）。review の本文は空でよい（`PUT .../reviews/{id}` に `body=''`）。
- diff 外への指摘は diff 内の関連行に付け、本文から head SHA のパーマリンクで参照する。

**Why:** 定型フッターはノイズ。skill の出力形式より本人の指示が優先する。
