---
name: issue-queue
description: キュー（pr-dispatch が自動で worker を起動する、ラベル付きの自分の issue）に仕事を入れる。`/issue-queue plan <テーマ>` はテーマを 1 PR に収まる issue に割って作り、`/issue-queue groom [件数]` はラベルの無い自分の open issue を読んで、ready にできるものにラベルを付ける。どちらも一覧を見せて 1 回だけ承認を取ってから付ける。5 PR 以上に割れる機械的な作業は、セッションで順に実装せずこれでキューに流す。
---

# /issue-queue

キューの仕組みは dotfiles の `home/scripts/pr-dispatch.sh`（キューの節）。ループは、自分がラベルを付けた自分の issue を見て、
worktree を作って `/issue-worker` を起動し、起動できたらラベルを外す。**ラベル = 付けた時点の内容への承認**で、
付けた後に本文や、それ以前の自分のコメントを編集すると、その issue は止まる。だから内容を全部整えてから、最後にラベルを付ける。

```bash
CONF="$HOME/Library/Application Support/pr-dispatch/config"
LABEL=$(sed -n 's/^queue_label=//p' "$CONF" | tail -n 1)
REPOS=$(sed -n 's/^queue_repos=//p' "$CONF" | tail -n 1)
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
```

`LABEL` が空、または `REPO` が `REPOS`（カンマ区切り）に無ければ、キューに入れられないと伝えて終わる（設定は人が書く）。

## ready の条件（worker が一人で draft PR まで進めてよいか）

- 期待する振る舞いが書いてあり、テストで表せる。
- 対象リポで完結する。公開 API の形・DB スキーマ・デプロイ設定・secret を変えない。
- 触るファイル 10 以下、差分 300 行以下の見込み、新しい依存なし、migration なし。
- Bug なら再現手順があるか、テストで再現できる見込みがある。
- 本文に「受け入れ条件（観測できる形）」「検証方法」「範囲外」がある（無ければコメントで足す。下の groom）。
- 題名が config の `ask_title_words`（既定は pr-dispatch.sh の `DEFAULT_TITLE_WORDS`）や `ask_labels` に当たらない、`no-agent` が無い。
  当たるものはラベルを付けても起動されない。

迷ったら ready にしない（「判断が要る」に入れる）。

## plan <テーマ>

1. テーマを読み、対象リポのコードを `rg` で当たって、**1 PR に収まる** issue に割る。各 issue の本文に
   「背景」「受け入れ条件（観測できる形）」「検証方法」「範囲外」を書く。順序があるものは依存（blocked by）で直列にする。
   上の条件に収まらないものは割り直すか、キューに入れない項目として分ける。
2. 一覧（題名・種別・依存・受け入れ条件の要約）を見せ、AskUserQuestion で **1 回だけ**承認を取る。
3. 承認されたものを**ラベル無しで**作る。依存の元になる issue から順に作り、番号を控える:
   `gh issue create --title "<題名>" --body-file <本文> --type <種別> [--parent <親>] [--blocked-by <番号,...>]`
   （`gh issue create` は issue を作ってから依存を設定するので、ラベルを同時に付けると、依存の無い ready な issue が一瞬見える）。
   一括で作るときは、作るたびに番号を一時ファイルへ追記し、途中で止まったらそれを見て残りだけ作る（そのまま再実行すると重複する）。
4. 種別・親・依存が付いたことを確かめる:
   `gh api graphql -F n=<番号> -f o=<owner> -f r=<repo> -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){issueType{name} parent{number} blockedBy(first:20){nodes{number}}}}}'`
5. 確かめられたものにだけ、最後にラベルを付ける: `gh issue edit <番号> --add-label "$LABEL"`。
   親（子 issue を持つ issue）には付けない（子のある issue は起動されない）。
6. 作った issue と、ラベルを付けた issue の番号を報告する。

## groom [件数]

1. ラベルの無い自分の open issue を、新しい順に最大 `件数`（既定 10）件読む:
   `gh issue list --author @me --state open --search "-label:\"$LABEL\" -label:no-agent" -L <件数> --json number,title,labels,updatedAt`。
   1 件ずつ `gh issue view <番号> --comments` と、本文が指すコードを読む。
2. 次の 4 つに分け、表で出す。
   - **このまま ready**: 上の条件を全部満たす。
   - **受け入れ条件を足せば ready**: 足す受け入れ条件・検証方法・範囲外の**案**を付ける。
   - **判断が要る**: 仕様・範囲を決める必要がある。何を決めるかを 1 行で。
   - **見送り**: 重複・既に直っている・大きすぎる。理由を 1 行で。
3. AskUserQuestion で、ready にするものを**まとめて 1 回**承認してもらう（複数選択）。
4. 承認されたものに、案があれば受け入れ条件を**コメントで**追記してから（`gh issue comment <番号> --body-file <案>`。**本文は書き換えない**）、
   最後に `gh issue edit <番号> --add-label "$LABEL"` を付ける。コメントがラベルより前にあることが、承認に含まれる条件。
5. ラベルを付けた issue の番号を報告する。

## してはいけないこと

- ラベルを付けた後に、その issue の本文やコメントを編集する（その issue は止まる。直すならラベルを外し、直してから付け直す）。
- 他人の issue にラベルを付ける・コメントする（起動されないうえ、他人への発信になる）。
- コードを書く、commit・push する、worktree を作る、`orca agent launch` を打つ（起動はループが行う）。
