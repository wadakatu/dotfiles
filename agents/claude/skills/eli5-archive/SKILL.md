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

## なぜこのスキルが必要か

eli5 プラグイン本体は `~/.claude/plugins/cache/` 配下のキャッシュで編集できない。
つまり「生成したら保存する」を仕込める場所は **このスキルの description による自動トリガーだけ**。
保存を忘れると Artifact は残っても一覧から辿れず、「後から見返せる」という当初の目的が崩れる。

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

保存先は `~/www/eli5/<category>/` 配下。**カテゴリ = ディレクトリ名** が唯一の情報源で、
これがそのまま一覧の見出しになる。メタデータファイルも front matter も持たない。

まず既存カテゴリを見て、当てはまるものがあれば **必ず再利用する**:

```
ls -d ~/www/eli5/*/ 2>/dev/null
```

当てはまらないときだけ新しいディレクトリを作る。名前は英語の kebab-case
（`network`, `security`, `web`, `database`, `ai`, `tooling` 等）。
既存カテゴリと意味が被る名前を増やさない（`db` と `database` を並立させない）。
どちらとも取れて判断に迷う場合だけ、ユーザーに「`network` と `security` どちらに入れますか？」と聞く。

### 3. ファイル名を決める

`<category>/YYYY-MM-DD-<english-kebab-slug>.html`。日付とスラッグがそのまま一覧の表示になるので、
**スラッグは内容が分かる英語の kebab-case**（`how-tcp-works`, `what-is-oauth`）にする。
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
> 同じ理由で、`main` にいる状態では hook の対象文字列を含むコマンドが弾かれる。
> ヒアドキュメント本文にその文字列が入るだけでも誤検知するので、長い本文は Write ツールで書く。

### 5. 保存してコミット・push

```
cd ~/www/eli5 && mkdir -p <category> && cp <生成した HTML のパス> ./<category>/$(date +%F)-<slug>.html
```

続けて別の Bash 呼び出しで add → コミット → push（メッセージは `Add: <topic を表す短い英語>`、
push 先は `-u origin add/<slug>`）。

### 6. PR を作って squash merge

```
gh pr create --repo wadakatu/eli5 --title "Add: <topic>" --body "<1〜2行の説明>"
gh pr merge --repo wadakatu/eli5 --squash --delete-branch
```

`gh pr merge` は hook の対象文字列に一致しないので `branch-guard` を通る。
**この自動 merge は `wadakatu/eli5` 限定**。他リポジトリに一般化しないこと。

merge 後にローカルを戻す: `cd ~/www/eli5 && git switch main && git pull`

### 7. 公開を確認してから完了と言う

Pages のビルドは 1〜2 分かかる。**built を確認し、実 URL が 200 を返すまで「保存した」と言わない**:

```
for i in $(seq 1 20); do
  s=$(gh api repos/wadakatu/eli5/pages/builds/latest --jq .status)
  echo "$s"; [ "$s" = "built" ] && break; [ "$s" = "errored" ] && break; sleep 10
done
curl -s -o /dev/null -w '%{http_code}\n' "https://www.wadakatu.dev/eli5/<category>/$(date +%F)-<slug>.html"
```

### 8. ユーザーに URL を返す

一覧 https://www.wadakatu.dev/eli5/ と、追加したページの直リンク、入れたカテゴリを提示する。

## 仕組み（触る前に知っておくこと）

`index.html` は Jekyll の `site.static_files` を走査し、`group_by_exp` でパス先頭の
ディレクトリ名ごとにまとめて一覧を自動生成する
（[Jekyll docs](https://jekyllrb.com/docs/liquid/filters/)、[変数](https://jekyllrb.com/docs/variables/)）。
だから **一覧もカテゴリ見出しも手編集は不要**。ディレクトリを掘れば増え、空になれば消える。

front matter を持たない HTML は Jekyll が変換も Liquid 展開もせず素通しする。
つまり eli5 の HTML に `{{ }}` や `{% %}` が含まれていても壊れない。
**逆に、保存する HTML に front matter を足してはいけない**（Jekyll がページ扱いして
一覧から消え、中身も Liquid 展開されて壊れる）。

リンクは `index.html` 側で相対パスとして出力している。この site は
`/eli5/` 配下で配信される project pages なので、ルート絶対パスにすると 404 になる。

## アンチパターン

- **Artifact を publish して終わりにする**: 一覧から辿れず目的を達成しない。publish と保存は両方やる。
- **「後で保存します」と言って次のターンへ持ち越す**: 忘れる。同一ターン内で完了させる。
- **HTML をリポジトリ直下に置く**: カテゴリ見出しが壊れる。必ず `<category>/` 配下に置く。
- **1 本ごとに新カテゴリを作る**: 見出しだらけで一覧の意味がなくなる。既存を先に探して再利用する。
- **ブランチ切り替えとコミットを 1 コマンドに繋ぐ**: `branch-guard` にブロックされる（手順 4 参照）。
- **main に直接コミットしようとする**: hook で弾かれる。必ず branch → PR → squash merge。
- **Pages のビルドを待たずに「保存しました」と報告する**: 404 の URL を渡すことになる。
- **保存する HTML に front matter を足す / `index.html` を手で書き換える**: 自動生成が壊れる。
- **日本語や大文字混じりのファイル名・ディレクトリ名にする**: URL が percent-encode されて扱いにくい。英語 kebab-case で統一する。
