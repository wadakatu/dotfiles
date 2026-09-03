---
name: eli5-archive
description: eli5 スキル（/eli5）が解説用の HTML を生成したら、必ず同一ターン内でこのスキルを起動し、wadakatu/eli5 リポジトリへカテゴリ分けして保存・公開する。「/eli5」を実行した直後、eli5 用の HTML を Write した直後、eli5 の Artifact を publish した直後は例外なくトリガーする。ユーザーが「eli5 のやつ保存して」「アーカイブして」「あれリポジトリに入れて」と言ったときも同様。
---

# eli5-archive

`/eli5` で作った HTML は Artifact として publish されるだけでは会話が終わると辿りにくい。
このスキルは、生成した HTML を **必ず** `wadakatu/eli5` リポジトリにカテゴリ分けして保存し、
GitHub Pages 上の恒久 URL をユーザーに返すまでを担保する。

- リポジトリ: https://github.com/wadakatu/eli5 (public)
- ローカル: `~/www/eli5`
- 公開 URL: https://www.wadakatu.dev/eli5/ （custom domain。`wadakatu.github.io/eli5/` も同じ内容を返す）

## トリガー

以下のいずれかに該当したら、**同じアシスタントターン内で** 最後まで実行する:

- `/eli5 <topic>` を実行した
- eli5 の解説 HTML を Write した / Artifact として publish した
- ユーザーが「保存して」「アーカイブして」「リポジトリに入れて」と言った

## 実行手順

### 1. リポジトリを最新化

```
cd ~/www/eli5 && git switch main && git pull
```

### 2. カテゴリを決める

保存先は `~/www/eli5/<category>/` 配下。**カテゴリ = ディレクトリ名** がそのまま一覧の見出しになる。

まず既存カテゴリを見て、当てはまるものがあれば **必ず再利用する**:

```
ls -d ~/www/eli5/*/ 2>/dev/null
```

当てはまらないときだけ新しいディレクトリを作る。名前は英語の kebab-case
（`network`, `security`, `web`, `database`, `ai`, `tooling` 等）。
既存カテゴリと意味が被る名前を増やさない（`db` と `database` を並立させない）。
どちらとも取れて判断に迷う場合だけ、ユーザーに「`network` と `security` どちらに入れますか？」と聞く。

### 3. ファイル名を決める

`<category>/YYYY-MM-DD-<english-kebab-slug>.html`。
日付は会話コンテキストの日付を信用せず `date +%F` で取る。

衝突していたら末尾に `-2`, `-3` を付ける（上書きしない）:

```
ls ~/www/eli5/<category>/$(date +%F)-<slug>*.html 2>/dev/null
```

### 4. ブランチを切る（**単独の Bash 呼び出しで**）

```
cd ~/www/eli5 && git switch -c add/<slug>
```

> **重要**: `branch-guard` hook は Bash 呼び出しが **始まった時点の HEAD** を見る。
> ブランチ切り替えとコミットを 1 コマンドに繋ぐと、切り替え前の main が判定されてブロックされる。
> **ブランチ切り替えと、コミット・push は必ず別々の Bash 呼び出しに分ける。**
> ヒアドキュメント本文に hook の対象文字列が入るだけでも誤検知するので、長い本文は Write ツールで書く。

### 5. 保存して組み立てる

```
cd ~/www/eli5 && mkdir -p <category> && cp <生成した HTML のパス> ./<category>/$(date +%F)-<slug>.html
```

続けて `tools/archive.py` を通す。**これを飛ばすと外枠が付かず、一覧にも載らない。**

```
cd ~/www/eli5 && python3 tools/archive.py <category>/$(date +%F)-<slug>.html
```

スクリプトは private 情報を検査し、共通の外枠（doctype・フォント・`eli5.css`・戻る線）を被せ、
`pages.json` に登録し、`index.html` を書き直す。冪等なのでやり直しても安全。

タイトルと概要は生成物の `<title>` と `<meta name="description">` から拾う。
どちらか欠けていたら失敗するので、`/eli5` 側で必ず書かせる。概要が比喩のままだったら
`--summary "…"` で具体的な一行に差し替える（一覧に出るのはこれ）。

**private リポジトリの情報を見つけたら保存を拒否する。** その場合は該当箇所を一般名詞に
言い換えてから再実行する（消すだけだと文が壊れる）。拒否されたら報告に出力をそのまま貼る。

検査は機械的にできる範囲（ticket 参照・`github.com/owner/repo`・ローカルパス・メール
アドレス・内部ホスト名・`~/.config/eli5/private-terms.txt` の固有名）だけを見る。
**教えていない内部クラス名やストア名は素通しする。** だから保存の前に本文を自分で読んで、
private な repo / サービス / クラス / チケットを指す語を一般名詞に置き換えること。
eli5 のたとえ話は元々抽象的なので、置き換えても内容は壊れない。

新しい private リポジトリの話を書いたときは、その名前を
`~/.config/eli5/private-terms.txt` に足す（このファイルは repo に置かない。private な
名前の一覧そのものが同じ情報を漏らすため）。

### 6. コミット・push

別の Bash 呼び出しで add → コミット → push（メッセージは `Add: <topic を表す短い英語>`、
push 先は `-u origin add/<slug>`）。`pages.json` と `index.html` も一緒に入ることを確認する。

### 7. PR を作って squash merge

```
gh pr create --repo wadakatu/eli5 --title "Add: <topic>" --body "<短い説明>"
gh pr merge --repo wadakatu/eli5 --squash --delete-branch
```

`gh pr merge` は hook の対象文字列に一致しないので `branch-guard` を通る。
**この自動 merge は `wadakatu/eli5` 限定**。他リポジトリに一般化しないこと。

merge 後にローカルを戻す: `cd ~/www/eli5 && git switch main && git pull`

### 8. 公開を確認してから完了と言う

Pages の配信まで 1〜2 分かかる。**built を確認し、実 URL が 200 を返すまで「保存した」と言わない**:

```
for i in $(seq 1 20); do
  s=$(gh api repos/wadakatu/eli5/pages/builds/latest --jq .status)
  echo "$s"; [ "$s" = "built" ] && break; [ "$s" = "errored" ] && break; sleep 10
done
curl -s -o /dev/null -w '%{http_code}\n' "https://www.wadakatu.dev/eli5/<category>/$(date +%F)-<slug>.html"
```

### 9. ユーザーに URL を返す

一覧 https://www.wadakatu.dev/eli5/ と、追加したページの直リンク、入れたカテゴリを提示する。

## 仕組み（触る前に知っておくこと）

**何もビルドしない。** GitHub Pages はブランチをそのまま配信し、`.nojekyll` が Jekyll を止める
（[docs](https://docs.github.com/en/pages/setting-up-a-github-pages-site-with-jekyll/about-github-pages-and-jekyll)）。
commit した内容がそのまま配信されるので、ローカルで開いて見えたものが本番で見えるもの。

- `eli5.css` — 全記事に共通のデザイン。色・書体・`e-` の部品はここだけ。
  **見た目を変えたいときはこの 1 ファイルを直して `--rebuild`**
- `tools/archive.py` — 保存時に走る唯一の道具。外枠を被せ、`pages.json` に登録し、
  `index.html` を書き出す。すでに組み立て済みのページは一度フラグメントに戻してから
  組み直すので、外枠を変えても全記事に反映できる
- `pages.json` — 一覧に出すタイトルと概要
- `index.html` — **生成物。手で編集しない**（`archive.py` が上書きする）

記事は完結した文書として配信されるが、書くのは body フラグメント。共通レイアウトを
当てられないのではなく、**当てる場所が `archive.py` になった**。

## アンチパターン

- **Artifact を publish して終わりにする**: 一覧から辿れず目的を達成しない。publish と保存は両方やる。
- **「後で保存します」と言って次のターンへ持ち越す**: 忘れる。同一ターン内で完了させる。
- **HTML をリポジトリ直下に置く**: カテゴリ見出しが壊れる。必ず `<category>/` 配下に置く。
- **1 本ごとに新カテゴリを作る**: 見出しだらけで一覧の意味がなくなる。既存を先に探して再利用する。
- **ブランチ切り替えとコミットを 1 コマンドに繋ぐ**: `branch-guard` にブロックされる（手順 4 参照）。
- **main に直接コミットしようとする**: hook で弾かれる。必ず branch → PR → squash merge。
- **Pages の配信を待たずに「保存しました」と報告する**: 404 の URL を渡すことになる。
- **`tools/archive.py` を通さずにコミットする**: 外枠が付かず、一覧にも載らず、private の検査も飛ぶ。
- **`index.html` を手で書き換える**: 次の保存で上書きされる。
- **記事ごとにパレットや書体を作り込む**: `eli5.css` に揃っているものを壊す。記事の `<style>` は絵のためだけ。
- **private リポジトリ名・issue / PR 番号・内部クラス名を残したまま保存する**: public リポジトリなので公開される。検査は補助であって保証ではない（手順 5 参照）。
- **日本語や大文字混じりのファイル名・ディレクトリ名にする**: URL が percent-encode されて扱いにくい。英語 kebab-case で統一する。
