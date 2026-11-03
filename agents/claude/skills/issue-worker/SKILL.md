---
name: issue-worker
description: issue-autopilot の worker。issue-autopilot が作った worktree の中で、1 つの issue を「失敗するテスト → 修正 → Codex レビュー → draft PR」まで進める。引数は `<N>` か `<N> --resume '<指示>'`。人が手で /issue-worker N と打っても同じ。
---

# /issue-worker

設計は dotfiles の `docs/issue-autopilot-design.md`（§4.4, §6, §7）。この worktree は issue `<N>` 専用。
人がいない前提で動く。止まって聞く代わりに `fail` で記録して終わる（`fail` がカードを Needs decision に出す）。

```bash
IA=~/www/personal/dotfiles/home/scripts/issue-autopilot.sh
"$IA" status | head -1   # repo= checkout= base= を読む
```

`fail` の書き方: `"$IA" fail <N> <code> "<補足 1 行>"`。呼んだらそれ以上の作業はしない。

## 手順

1. **setup を待つ**（`--resume` なら飛ばす）。`orca terminal list --worktree current --json` で Setup タブを見つけ、
   出力の末尾に `Orca setup done:` の行が出るまで 60 秒おきに最長 20 分待つ。生成物の有無では判定しない。
   - 行が無く、Setup タブが終わっている（`connected == false` か行が消えた）ときだけ、
     `"$(git rev-parse --git-dir)/setup-retry"` が無ければそれを置いて（commit に入らない場所）1 回だけ同じ script を流す:
     `orca repo show --repo "path:<checkout>" --json | jq -r '.result.repo.hookSettings.scripts.setup' | ORCA_WORKTREE_PATH="$PWD" bash`
   - `connected == true` の間は待つだけ。それでも印が出なければ `fail <N> setup "<末尾の行>"`。
2. **再確認**: `"$IA" recheck <N>`。
   - `ok` → 続ける。
   - `gone` / `owner` / `pr-exists` → `fail <N> <その語>`。
   - `changed` → issue を読み直し、`/issue-autopilot` の go 条件を満たすなら `"$IA" verdict <N> go "changed ok"` で続ける。満たさなければ `fail <N> changed`。
   - `error` → 5 分待って 1 回だけやり直し、駄目なら `fail <N> recheck`。
   - `gh issue view <N> -R <repo> --comments` を読み、誰かが「対応します」「PR を出した」と書いていれば `fail <N> owner`。
3. **再現**: 対象リポの規約（`AGENTS.md` / `CLAUDE.md`）どおりにテストを書き、**修正前に落ちる**のを見る。
   落ちたテスト名と失敗の行を控える。再現できなければ `fail <N> unclear`。
4. **修正**: 最小の差分で直し、そのテストと関係するテストを流す。2 回直しても赤なら push せず `fail <N> red "<テスト名>"`。
   作業中に go 条件を外れた（ファイル 10 超・300 行超・依存追加・migration・API の形が変わる）と分かったら `fail <N> scope`。
5. **commit**: 英語の Conventional Commits。`Co-Authored-By` は付けない。
6. **Codex レビュー**: `pgrep -f '[c]odex exec' | wc -l` が 4 未満になるまで 5 分おきに待つ。
   開始から 4 時間で空かなければ PR を作らず `fail <N> review-pending`。空いたら Bash を `run_in_background: true` で:
   `codex exec -C "$PWD" -s read-only -o "$TMPDIR/issue-<N>-review.md" review --base origin/<base> < /dev/null`。
   指摘はコードで裏を取ってから直し、直したらテストを流し直す。
7. **draft PR**: `git push -u origin HEAD` → `gh pr create --draft`。本文は `/pr` skill の形で、
   - 「検証:」に修正前に落ちたテスト名と修正後の結果、
   - `## 関連情報` に `Closes #<N>` と「issue-autopilot による自動作成、Codex レビュー済み」。
   作ったら `"$IA" done <N> <PR の URL>`。

## `--resume '<指示>'`

人の指示を最優先に読む。先に `gh pr list -R <repo> --head "$(git branch --show-current)" --state open --json url -q '.[0].url'` で
自分の PR を探し、あれば作り直さず、指示の分だけ直して push し、`"$IA" done <N> <その URL>` で終える
（`recheck` はその自分の PR を `pr-exists` と数えるので呼ばない）。無ければ手順 2 から続ける。既にある commit は作り直さない。

## してはいけないこと

- マージ、`gh pr ready`、本番ブランチ（base）への push。
- 他人の PR・issue へのコメント、Slack・メール。自分の issue にも書かない。
- デプロイ設定・IaC・CI のワークフロー・secret に触る。本番の読み書き。migration の追加（`fail <N> scope`）。
- `.env*` と `*_key.json` を読む。
- `orca agent launch`、`orca worktree create`（別の worker を生まない）。
- AskUserQuestion で止まる（人はいない。`fail` で記録する）。
