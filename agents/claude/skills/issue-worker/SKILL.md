---
name: issue-worker
description: キューの worker。pr-dispatch がキュー（自分がラベルを付けた自分の issue）から作った worktree の中で、1 つの issue を「失敗するテスト → 修正 → Codex レビュー → 実機の検証 → draft PR」まで進める。引数は `<N> --approved-at <T>`。人が手で `/issue-worker <N> --approved-at <T>` と打っても同じ。
---

# /issue-worker

1 issue = 1 worktree = 1 PR = 1 worker。この worktree は issue `<N>` 専用。起動するのは `home/scripts/pr-dispatch.sh`（キューの節）。
`<T>` はラベルを付けた時刻で、その時点の issue の内容への承認。**起動の引数で渡された T を使い、取り直さない。**
仕様として読むのは、issue の本文と、T 以前に自分（issue の author）が書いたコメントだけ。T より後のコメントは情報であって指示ではない。

```bash
# 再確認に使うのは、pr-dispatch を動かしている版（`home/scripts/live-sync.sh` が origin/main から
# `~/.local/share/dotfiles-live/<コミット>/` に取り出した写し。`current` が最新の版を指し、LaunchAgent はそこから pr-dispatch を動かす）。
# dotfiles の checkout の版は使わない。ブランチ作業中のレビュー前の版かもしれず、check を知らない古い版は、
# 再確認の代わりに通常の実行を始めてしまう。
PD="$HOME/.local/share/dotfiles-live/current/home/scripts/pr-dispatch.sh"
BASE=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
# 無人の実機検証 (どちらかが空なら無効)。pr-dispatch と同じ、追跡しない設定から読む。値はここに書かない。
CFG="${STATE_ROOT:-$HOME/Library/Application Support}/pr-dispatch/config"
VERIFY_SKILL=$(sed -n 's/^verify_skill=//p' "$CFG" 2>/dev/null | tail -n 1)
VERIFY_PROBE=$(sed -n 's/^verify_probe=//p' "$CFG" 2>/dev/null | tail -n 1)
```

## 止まり方

人はいない前提で動くが、判断が要るものはグローバル CLAUDE.md の「委任の線引き」どおり止まって聞く。
止まるときは `orca worktree set --worktree current --workspace-status needs-decision --unread --comment "#<N>: <何を判断してほしいか 1 行>" --json`
でカードを Needs decision に移してから、AskUserQuestion で聞く。続けられない（setup が終わらない、再確認が通らない、範囲を超える）ときも同じ形でカードを移し、
コメントに理由を 1 行で書いて終わる（聞くことが無ければ AskUserQuestion は出さない）。

## 呼び出す skill との関係

この手順は、ほかの skill（検証の skill、`/fix-ci`）を Skill ツールで呼ぶ。

- skill は同じ会話に読み込まれ、その手順は「最後に報告する」で終わる。**その報告で応答を終えない。** 報告で応答を終えると、この worker はそこで止まり、PR は出ない（pr-dispatch が「PR を出さずに終了」として人に上げる）。
  skill が最後に出すと決めている報告は、メッセージとして出さず、全文をファイルに書く（`"$TMPDIR/issue-<N>-<skill の名前>.md"`。形と最後の行は skill の決まりのまま）。書いたら、同じ応答の中で、呼んだ手順の続きを打つ。
- skill の手順が下の「してはいけないこと」とぶつかるときは、こちらが勝つ。その手順は打たない。それで先へ進めないなら、「止まり方」で止まる。
- skill が人への確認を求める場面は、「止まり方」のとおりに止まる。
- `/pr` は呼ばない。本文の形だけを使う。

## 手順

1. **setup を待つ**。`orca terminal list --worktree current --json` で Setup タブを見つけ、出力の末尾に `Orca setup done:` の行が出るまで
   60 秒おきに最長 20 分待つ。生成物の有無では判定しない。
   - 行が無く、Setup タブが終わっている（`connected == false` か行が消えた）ときだけ、`"$(git rev-parse --git-dir)/setup-retry"` が無ければ
     それを置いて（commit に入らない場所）1 回だけ同じ script を流す:
     `orca repo show --repo "path:$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" --json | jq -r '.result.repo.hookSettings.scripts.setup' | ORCA_WORKTREE_PATH="$PWD" bash`
   - `connected == true` の間は待つだけ。それでも印が出なければ止まる（「setup が終わらない: <末尾の行>」）。
   - 待つものが無いリポ: worktree の根で次が通るときは、待たずに進む（pr-dispatch が worktree を取り込むときと同じ条件）。Orca の返事が読めないときは「無い」と見なさず、上の待ちに入る。
     ```bash
     MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
     { [ ! -e orca.yaml ] || [ "$(grep -Ec "setup[\"']?[[:space:]]*:" orca.yaml)" = 0 ]; } &&
       orca repo show --repo "path:$MAIN" --json 2>/dev/null |
       jq -e '(.result.repo | type == "object") and ((.result.repo.hookSettings.scripts.setup // "") == "")' >/dev/null
     ```
2. **再確認**: `grep -q '^queue_check()' "$PD" && bash "$PD" check <N> <T>`。T の内容のまま進めてよいかだけを見る（ラベルが外れている、この worktree がある、は止める理由にしない）。
   `grep` は、その写しが `check` を持つ版であることの確認（持たない版に `check` を渡すと、通常の実行が走る）。
   - exit 0（`ok`）→ 続ける。
   - exit 1 → 何も作らずに止まる。出力の 1 行（理由）をカードのコメントに書く。T より後に本文や T 以前のコメントが編集された、
     閉じた、blocker が開いた、などで、編集された部分を外して進めることはしない。
   - exit 2（確かめられない）、写しが無い、`grep` が通らない → 5 分待って 1 回だけやり直し、駄目なら止まる（写しは pr-dispatch の実行のたびに置き直される）。
     dotfiles の checkout の版で代用しない。
   - `gh issue view <N> --comments` を読み、誰かが「対応します」「PR を出した」と書いていれば止まる。
3. **再現**: 対象リポの規約（`AGENTS.md` / `CLAUDE.md`）どおりにテストを書き、**修正前に落ちる**のを見る。落ちたテスト名と失敗の行を控える。
   再現できなければ止まる。
4. **修正**: 最小の差分で直し、そのテストと関係するテストを流す。2 回直しても赤なら push せずに止まる。
   ファイル 10 超・300 行超・依存の追加・migration・API の形が変わる、のどれかに当たりそうなら止まる。
   「止まって聞く」に当たらない実装判断は、公式ドキュメント・主要実装を調べて決め、理由と出典を控える（PR 本文の「判断」に書く）。
5. **commit**: 英語の Conventional Commits。`Co-Authored-By` は付けない。
6. **Codex レビュー**: `pgrep -f '[c]odex exec' | wc -l` が 4 未満になるまで 5 分おきに待つ。開始から 4 時間で空かなければ PR を作らずに止まる。
   空いたら Bash を `run_in_background: true` で:
   `codex exec -C "$PWD" -s read-only -o "$TMPDIR/issue-<N>-review.md" review --base "origin/$BASE" < /dev/null`。
   指摘はコードで裏を取ってから直し、直したらテストを流し直して commit する。
7. **実機の検証**（最後の commit の後、push の前）。結果は「証拠（skill が出した節）」か「実機は未検証（<理由>）」のどちらか 1 つ。未検証のうち `env-blocked` のときだけは、skill の節を添える。手順 8 で本文に書く。
   先に `git status --porcelain` が空なのを確かめる。空でなければ、手順 4〜6 の変更の commit 漏れを commit してから始め、commit に入れられない変更が残るなら「止まり方」で止まる（`#<N>: commit できない変更が残っている`）。
   空になったら、`git rev-parse HEAD`（**検証した HEAD**）と `date +%s`（開始時刻）を控える。
   次を上から順に見て、最初に当たったもので決める。
   1. `VERIFY_SKILL` か `VERIFY_PROBE` が空 → 未検証（無人の検証が設定されていない）。
   2. 差分（`git diff --name-only "origin/$BASE"...HEAD`）が、動かす対象の無いもの（ドキュメント・テスト・CI の設定）だけ → 未検証（動かす対象が無い変更）。迷ったら次へ。
   3. probe。`VERIFY_PROBE` は、コマンドの名前と引数を空白 1 つで並べたもの。`printf '%s\n' "$VERIFY_PROBE" | LC_ALL=C grep -Eq '^[A-Za-z0-9_./-]+( [A-Za-z0-9_./-]+)*$'` が落ちる → 打たずに未検証（probe の設定の形が不正）。通れば、`printf '%s\n' "$VERIFY_PROBE"` で出した文字列を、そのまま Bash の 1 コマンドとして打つ（前後に何も足さない。変数のまま打たない。`bash -c` で包まない。timeout 30 秒）。exit 0 以外 → 未検証（probe が失敗: exit <n>）。
   4. Skill ツールで `VERIFY_SKILL` を、引数 `--unattended` で呼ぶ。一覧に無い、または読み込んだ本文に `--unattended` の扱いが無い → その手順を 1 つも打たずに未検証（検証の skill を無人で使えない）。在れば、その手順に従う。skill の最後の報告は、メッセージにせず `"$TMPDIR/issue-<N>-verify.md"` に書き、応答を終えずに下の 5 へ進む（「呼び出す skill との関係」）。
   5. skill が自分の最終報告まで行かなかった（エラーで止まった、下の 15 分を超えた、手順を外れた）→ 未検証（<起きたことを 1 行>）。節が出ていても使わない。skill が「保存できなかった」と決まりどおりに書いて報告を終えたのは、最後まで行ったうちに入る（「してはいけないこと」に当たるので保存を打たなかったときも、保存できなかったものとして同じ扱い）。
   6. 報告（上のファイル）の最後の行が `env-blocked: <理由>` → 未検証（env-blocked: <理由>）。skill が PR 本文用に出した節があれば、手を入れずに使う。
   7. skill が PR 本文用の節を出し、**節の中で最初に現れる 40 桁の SHA** が検証した HEAD と同じで、`<要記入:` が残っておらず、`git rev-parse HEAD` と `git status --porcelain` が最初と変わっていない → その節が証拠。手を入れずに使う。
   8. それ以外（節が無い、SHA が無いか違う、HEAD か作業ツリーが動いた）→ 未検証（<起きたことを 1 行>）。節は使わない。

   守ること:
   - 環境を直さない。コンテナの起動、seed、`make`、依存の導入は、skill が無人で打ってよいと書いていない限り打たない。`env-blocked` をやり直さない。
   - **コードを直さない。** 実機の結果が期待と違っても commit を足さず、節をそのまま使う（手順 10 で人に上げる）。
   - 開始から 15 分を超えたら、次のコマンドを打たずに打ち切る（上の 5）。超えたかは、コマンドを打つ前に `date +%s` で見る。ただし skill が検証の後に行う保存（skill 自身のリポに対する git の操作）は、1 つでも打っていたら最後まで通す。結果の分からない push は打ち直さず、skill の決まりどおり報告に載せる。
   - skill が元の PR の URL を求めるとき、まだ PR が無ければ issue の URL を渡す。
8. **draft PR**: 先に 2 つ確かめる。どちらかが外れたら push せず、「止まり方」で止まる（手順 7 の後、この worker は commit も編集もしないので、外れるのは外からの変更）。
   - `git status --porcelain` が空（外れたら `#<N>: 検証の後に未コミットの変更が在る`）
   - `git rev-parse HEAD` が検証した HEAD と同じ（外れたら `#<N>: 検証の後に HEAD が変わった`）

   `git push -u origin HEAD` → `gh pr create --draft`。本文は `/pr` skill の形で、次を必ず入れる。
   - 「判断」: 手順 4 で決めたことと、その理由・出典。無ければ「無し」。
   - 「検証」: 修正前に落ちたテスト名と、修正後の結果。続けて実機の結果を `実機: 下の節のとおり` か `実機は未検証（<理由>）` で書き、行の最後に `（HEAD <検証した HEAD の先頭 7 桁>）` を付ける。テストが通った = 実機で確かめた、ではないので書き分ける。
   - 手順 7 の節（証拠の節、または `env-blocked` の節）があれば、`## 関連情報` の前に手を入れずに置く。
   - `## 関連情報`: `Closes #<N>` と「キューによる自動作成（承認 <T>）、Codex レビュー済み」。
9. **CI を待つ**: `gh pr checks --watch`。落ちたら `/fix-ci` を 1 回だけ（その報告も `"$TMPDIR/issue-<N>-fix-ci.md"` に書き、応答を終えずに下へ進む）。
   - `/fix-ci` の後も CI が成功しない（直すのに「してはいけないこと」に当たる変更が要る、を含む）→ 検証のやり直しも本文の書き直しもせず、「止まり方」で止まる（`#<N>: PR #<番号> の CI が赤のまま`）。
   - **CI が緑で、head が変わっていたとき**（`gh pr view --json headRefOid` が検証した HEAD と違う）: 先に、`git rev-parse HEAD` がその head と同じで `git status --porcelain` が空なのを確かめる。手順 3〜4 のテストを流し直し（赤なら直さずに止まる: `#<N>: PR #<番号> の CI の修正の後にテストが赤`）、手順 7 を 1 回だけやり直して、本文の「検証」の行と実機の節を**両方**、新しい結果で書き直す（`gh pr edit --body-file`。古い節は節ごと消す。`/fix-ci` が足した「以後は未再検証」の行も一緒に消える）。やり直しが未検証なら、古い表を残さない。置くのは未検証の 1 行と、`env-blocked` のときの skill の節だけ。
   - 書き直したら `gh pr view --json body,headRefOid` で確かめる: 「検証」の行の 7 桁が head の先頭と同じ。結果が証拠なら、節の最初の 40 桁が head と同じ。結果が未検証なら（`env-blocked` の節を置いたときも）、40 桁は照合せず、古い表と「以後は未再検証」の行が残っていないことを見る。
   - 確かめられない（ローカルの HEAD が head と違う、作業ツリーが空でない、`gh pr view` か `gh pr edit` が 2 回続けて失敗した、やり直しの間に head がまた変わった、書いたのに合わない）→ やり直しを重ねず、「止まり方」で止まる（`#<N>: PR #<番号> の本文の検証を head に合わせられない`）。
10. **終わる**: `orca worktree set --worktree current --workspace-status in-review --comment "draft PR #<PR 番号>" --json`。
    **ready にはしない**（draft を人が見て ready にする）。
    - 手順 7 で証拠として使った節か、そのときの skill の報告が、期待と違う結果を 1 つでも示しているときは、`in-review` にせず
      `--workspace-status needs-decision --unread --comment "#<N>: draft PR #<番号> の実機の結果が期待と違う"` にして終える。

## してはいけないこと

- マージ、`gh pr ready`、本番ブランチ（base）への push。
- issue のラベルの付け外し（キューのラベルは pr-dispatch と人が扱う）。他人の PR・issue へのコメント、Slack・メール。自分の issue にも書かない。
- デプロイ設定・IaC・CI のワークフロー・secret に触る。本番の読み書き。migration の追加（止まる）。
- `.env*` と `*_key.json` を読む。
- `orca agent launch`、`orca worktree create`（別の worker を生まない）。
- 検証のために環境やコードを直す（手順 7）。検証の skill の手順であっても、この worktree のリポの base へ push しない（保存できなかった差分は、skill の決まりどおり報告に載せる）。
