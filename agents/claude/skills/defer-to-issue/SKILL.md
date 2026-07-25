---
name: defer-to-issue
description: Use this skill whenever you are about to defer work to a separate GitHub issue or PR — phrases like "別 issue で対応", "別 PR で対応", "follow-up issue を立てる", "issue 化", "別途 issue", "後続 PR で", "track separately", "out of scope, will file an issue" 等を発言する直前 / 直後に必ずトリガーする。これは「言ったのに作らない」事故を防ぐためのスキル。重複 issue の検知もここで担う。
---

# defer-to-issue

レビューコメントへの返信、PR 説明、コミットメッセージ、会話中などで「これは本 PR の範囲外なので別 issue / 別 PR で対応します」系の発言をする際、その発言と **同じターン内** で実際に GitHub issue を作るためのスキル。

## なぜこのスキルが必要か

人間のレビュワーから見ると「別 issue で対応します」は **約束** だが、LLM の応答ループでは口約束のまま流れて忘れられやすい。実際に過去 PR #NNNN のレビュー対応で、reply に「別 issue で対応」と書きながら作成し忘れ、ユーザーから「issue は作成しましたか？」と確認される事例が発生した。

このスキルの目的は、deferral 文言を出すこと自体を **issue 起票のトリガー** に変え、reply / 説明に issue 番号を載せる前に一度立ち止まることにある。

## トリガーフレーズ

以下のいずれかを発言する／発言しようとしているとき:

- 「別 issue で対応」「別 issue を立てる」「別途 issue 化」「issue 化して後続で」
- 「別 PR で対応」「後続 PR で対応」「フォローアップ PR」
- 「本 PR のスコープ外」+ 「対応します／対応する」
- 「track separately」「file a follow-up issue」「out of scope, separate PR」
- 「後で direct する」「あとで切り出す」（issue/PR の切り出しを示唆する場合）

定型文 "Look for X in Y" に頼らず、**deferral の意図** が読み取れたら起動する。

## 実行手順

### 1. deferral の中身を抽出

issue にする内容を、自分の reply 草稿から抽出する:

| 項目 | 抽出元 |
| --- | --- |
| **タイトル** | 「何を直すのか」を 1 行で。`<カテゴリ> — <対象 / 修正内容>` 形式が読みやすい（例: `impl — SomeController::put() で 500 → 404 に修正`） |
| **背景** | 元のレビューコメント / PR / file:line / 該当コミットへのリンク |
| **問題** | なぜ修正が必要か（テスト失敗、規約違反、UX、セキュリティ、誤実装、etc.） |
| **やること** | 想定する diff / 変更ポイント。CodeRabbit が `suggestion` を出していればそれを引用 |
| **ゴール** | 完了条件（テストが green、failure が 0、etc.） |

reply の自然言語を膨らませて issue 本文にする。reply 側は短く保ち、「詳細は issue で」と倒すのが読みやすい。

### 2. 重複チェック（必須）

issue を作る前に、`gh issue list --search` で同主旨の既存 issue がないか確認する。**ヒットしたらスキップして既存番号を使う**。

```bash
# キーワード検索 (タイトル + 本文)
gh issue list --repo <owner>/<repo> \
  --search "<重複検知用キーワード> in:title,body" \
  --state all --limit 5 \
  --json number,title,state,url
```

検索キーワードの選び方:

- **対象シンボル / API パス** をそのまま入れる（`SomeController::put`, `SomeListResponse cursor`, `/v2/some/{id}/path` など）
- ファイル名 + 動作（`phpunit.xml schema 13`）
- 過度に一般的なキーワード（`bug`, `fix`）だけだと無関係 issue が大量にヒットするので **必ず固有名と組み合わせる**

判定:

- ヒット 0 件 → 新規作成へ
- 完全一致 / 高い類似度のヒット → 作成スキップ。既存 issue 番号 (例 `#1234`) を reply に流用する
- 類似度が微妙 → タイトル / 本文を読んで人間判断。境界例ならユーザーに「既存 #N と統合しますか？それとも別建て？」と聞く

判断に迷ったらユーザーに確認する側に倒す。誤って似て非なる issue を「重複」扱いして閉じるよりは、確認のオーバーヘッドの方が安い。

### 3. issue 作成

重複なしなら作成。リポジトリのラベル規約に従う（不明なら一度 `gh label list` で確認）。

リポジトリに **Issue Type（Bug / Feature / Task）運用がある場合は必ず設定する**。`gh issue create` には `--type` が無いため、その場合は GraphQL mutation で作成する（例: work-api は CLAUDE.md の「GitHub Issue 運用」節に repoId と Issue Type ID 付きのコマンドが明記されている。type 未設定だと needs-triage が自動付与される）。

```bash
gh issue create --repo <owner>/<repo> \
  --label <既存ラベル> \
  --title "<カテゴリ> — <対象 / 修正内容>" \
  --body "$(cat <<'EOF'
## 背景

PR #XXXX review thread (#XXXX (comment) [#NNNNNN](https://github.com/<owner>/<repo>/pull/XXXX#discussion_rNNNNNN)) で <reviewer> が指摘。本 PR では <理由> のためスコープ外として切り出し。

## 現状

<該当ファイル:行 や code block の引用>

## 問題

<なぜ直すべきか>

## やること

<具体的な diff / 手順>

## ゴール

- <完了条件 1>
- <完了条件 2>
EOF
)"
```

タイトルと本文は **issue 単独で読んで自己完結** するように書く。「PR #NNNN で言ったあれ」だけだと未来の自分・他人が辿れない。

### 4. reply / PR 本文に issue 番号を埋め込む

issue を作った直後（あるいは作成と同じターン）に、deferral を書いた箇所へ番号を反映する:

- レビューコメントへの reply: `... ここは別途 issue 化して後続で対応します。 → #NNNN` のように 1 行で番号を書き添える
- PR description の「フォローアップ Issue」セクションに追加
- すでに「別 issue で対応」と書いた reply を投稿してしまった場合は、**追加 reply** で `follow-up issue 起票しました: #NNNN` を投げる（既存 reply は編集できない / しないことが多い）

### 5. 既存 issue を流用したケース

重複検知でスキップした場合も、reply に番号を残す:

```
（同主旨の既存 issue があるためそちらに集約します: #1234）
```

これで「issue を作っていないのに番号もない」状態を防げる。

## アンチパターン

- **「あとで作ります」と書いて作らない**: このスキルが阻止すべき第一の事故。deferral を発言した時点で必ずこのスキルを通す。
- **同じターン内で issue 化を完了しない**: 後続のターンで「やっぱり忘れた」を防ぐため、原則として deferral 発言と同じアシスタントターン内で `gh issue create` まで完了させる。
- **重複チェックなしで作る**: 同じ問題に対する issue が複数立つとトリアージが破綻する。`gh issue list --search` の手数は必ず払う。
- **タイトルに PR 番号や日付しか書かない**: 「PR #NNNN のフォローアップ」だけでは検索性ゼロ。**何を直すのか** を主語にする。
- **本文を空にする / `-b ""` で作る**: 後で読み返したとき何の情報もないので、最低限「背景・問題・やること・ゴール」の 4 セクションは入れる。

## 実例（PR #NNNN で実際に作った issue）

reply:

> 「不存在 → 500 ではなく 404 が正しい」という指摘自体には同意なので、ここは別途 issue 化して後続で対応します。

→ 同ターン内で `gh issue list --search "SomeController 404"` でゼロヒット確認 → `gh issue create` で #NNNN を作成 → 同 thread に `follow-up issue 起票しました: #NNNN` を投稿、PR description のフォローアップ節にも追加。

## 関連スキル

- `/review-pr-comments` (slash command): 対応不要のコメントに `-1` リアクションを付け reply で理由説明する流れの中で、本スキルが噛み合う。
