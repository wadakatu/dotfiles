# issue-autopilot 設計書（改訂 2）

対象: Orca v1.4.246 / Claude Code 2.1.316 / studio-design/studio-api（Orca repo `app`、主 checkout `$HOME/www/dev/app`、default branch `dev`）。
書式は `docs/agent-gc-design.md` に倣う。出典は `path:line` か公式 docs の URL。推測には「推測」と書く。
改訂 2 は Codex の設計レビュー（17 件）を反映した。レビューの主張はコードと help で裏を取ってから採った。

## 1. 意図と決まっていること

自分が author の open issue を Orca の automation が拾い、issue ごとに worktree を作り、エージェントが **draft PR の作成まで** 進める。ready 化・マージは人。

決定済み（変えない）:
- ラベルでの opt-in はしない。author=@me の open issue は全部候補（今日 174 件）。opt-out は `no-agent` ラベルだけ。
- 実装前に「一人で進めてよいか」を判定し、曖昧・仕様判断・auth・個人情報・本番・課金・セキュリティは実装せず Needs decision に上げる。判定は worktree を作る前に行い、判断待ちの issue には worktree を作らない。
- 1 issue 1 PR。量は 1 日あたりで絞る。
- 最初は api リポだけ。

線引きはグローバル CLAUDE.md「委任の線引き」（`~/.claude/CLAUDE.md:87-119`）そのまま。新しく PR にするものは必ず Codex の実装レビューを通す（同 :70-71）。

Cursor pstack の benny（https://github.com/cursor/plugins/tree/main/pstack/automations/benny、skill 本文は https://raw.githubusercontent.com/cursor/plugins/main/pstack/automations/benny/skills/reproduce-and-fix-issues/SKILL.md）から借りる考え: 着手前に誰かが持っていないかを見直す（ownership gate、同 §3）、修正の前に再現する・症状を 2 回観測する（同 §7）、予算と範囲に収まるかを先に判定する（bounded fix）、修正前後の証拠を残す、draft PR のみでマージもデプロイもしない（同 §14）、triage と修正を分ける（README）。節番号はレビューの指摘で確認したもの。

## 2. 全体像

```
Orca automation "issue-autopilot"
  --trigger "0 */2 * * *" --provider claude
  --workspace "path:$HOME/www/orca/app/issue-autopilot" --workspace-mode existing
  --precheck "$HOME/www/personal/dotfiles/home/scripts/issue-autopilot.sh candidates" --precheck-timeout 120
  --prompt "/issue-autopilot"
  │
  ├ precheck: candidates   ← スクリプト。GitHub 1 回 + Orca 2 回。未判定 or 実行待ちが無ければ exit 1
  ▼
  dispatcher session (/issue-autopilot, Sonnet)       ← 未判定の候補を triage。コードは書かない
  │   issue-autopilot.sh verdict <N> go|ask|skip "<1行>"  ← 判定キャッシュ。go は job (pending) を作る
  │   issue-autopilot.sh dispatch                          ← pending を上限内で起動。ロック・予約・状態遷移はスクリプト
  ▼
  worker session per issue (/issue-worker <N>, Opus)  ← setup 完了待ち → 再確認 → 再現 → 修正 → テスト → codex review → draft PR
  │   issue-autopilot.sh done <N> <pr-url>              ← 成功の定義。これが無い終了は失敗
  ▼
  人が ready 化 → pr-dispatch / worktree-gc（既存）
```

役割分担:

| 段階 | 誰が | 根拠 |
|---|---|---|
| 候補抽出・重複除外・ルール判定・上限・ロック・状態遷移 | `issue-autopilot.sh`（LLM なし） | 機械的に決まるものは AI に任せない（`home/pr-dispatch.nix:7-8`） |
| 曖昧さ・範囲の判定（triage） | dispatcher session。Sonnet、effort medium | issue と該当コードを読むだけ |
| 実装〜draft PR | worker session。Opus、effort high | 既存の開発フロー（`~/.claude/CLAUDE.md:65-68`） |
| 実装レビュー | `codex exec -C <wt> -s read-only review --base origin/dev` | 必須（同 :70-71）。枠 4 を共有（`~/.claude-shared-memory/orca-parallel-agent-pipeline.md:34`） |
| ready 後の CI / conflict / レビュー対応 | pr-dispatch（既存、非 draft のみ `pr-dispatch.sh:104`） | 人が ready にした後 |
| マージ後の片付け | worktree-gc（既存） | `home/scripts/worktree-gc.sh:162-226` |

automation は 1 つ。benny の「triage と修正を分ける」は、判定（`verdicts`）と実行待ち（`jobs`）を別の state にし、`dispatch` が設定ファイルの `dispatch_enabled` を毎回読む（§8）ことで実現する。段階導入では `dispatch_enabled=false` で triage だけ回る。

dispatcher の実行場所は `app` の専用 worktree `issue-autopilot`（ブランチは push しない、コードを触らない）。判断待ちの集約カードも兼ねる（§4.3）。

Orca automation を選んだ理由: run 履歴と terminal を Orca が持ち、`--precheck` で安い判定を前段に置ける（https://www.onorca.dev/docs/cli/automations、`orca automations create --help` 行 44-46）。`orca automations run` は precheck を飛ばす（同 行 46）ので、skill の最初の手順でも `candidates` を呼ぶ。`--reuse-session` は使わない（`--extra-agent-args` と併用不可、同 行 48）。

worker の起動（`dispatch` の中、ロック内）:

```
orca worktree create --repo "path:$HOME/www/dev/app" --name "issue-$N-$slug" --branch "issue-$N-$slug" \
  --issue "$N" --base-branch origin/dev --setup run --no-parent --json
```

- `path:~/...` は展開されず `repo_not_found` になる（`orca repo show` で確認済）。`--branch` が無いと設定済みの接頭辞（実環境は `wadakatu/…`）が付く（`orca worktree create --help` 行 49）。取られていた名前には数字の接尾辞が付くので、戻り値の実ブランチ名と worktree id を state に保存する。
- `--agent` は付けない。repo の `setupAgentStartupPolicy` が `start-immediately` なので、付けると setup 完了前にエージェントが動く（`orca repo show` で確認）。worker は別途 `orca agent launch --agent claude --worktree "id:<worktreeId>" --model opus --effort high --surface chat --prompt "/issue-worker $N" --json` で起動し、setup の完了待ちは worker の最初の手順にする（§7）。
- 起動の返事が失われたら、同じコマンドをエラーに含まれる `--retry-launch <operationId>` 付きで再発行し、新規起動として再試行しない（`orca worktree create --help` 行 53、`orca agent launch --help` 行 27）。
- `--surface chat` は、対象エージェントが chat を開けないと terminal に fallback する（`orca agent launch --help` 行 23）。どちらで開いたかは `result.launch.outcome.kind` に出る（`worktree create --help` 行 54）。保存する。

## 3. 候補抽出と重複防止（`candidates`、precheck）

precheck の既定 timeout は 60 秒（`--help` 行 45）。174 件に対して issue ごとに GitHub を叩くと収まらないので、precheck は一括取得 3 回だけにし、issue 単位の照合は `dispatch` に回す。timeout は 120 秒にする。

1. `gh issue list -R studio-design/studio-api --author @me --state open -L 500 --json number,title,labels,updatedAt,assignees`。500 件返ったら打ち切りとみなして exit 1（今日は 174 件）。
2. `orca worktree list --json`（`repoId`, `linkedIssue`, `linkedItems`, `branch`, `path`）と `orca worktree ps --json`。`.ok != true` か `.result.truncated == true` なら exit 1（`worktree-gc.sh:75` と同じ）。
3. 除外（ルール、LLM なし）:
   - ラベル `no-agent`、`tracking`（12 件）、`Stale`（3 件）。
   - assignee に自分以外がいる（ownership gate）。
   - worktree がある: `repoId` が `app` の repo id（`141d1cc3-…`）で、`linkedIssue == N` か `linkedItems` に issue URL を含むか、branch が `issue-<N>-` で始まる。
   - `jobs.tsv` に終端でない job がある（§3.1）。
   - `verdicts.tsv` に同じ `(number, updatedAt)` の判定がある。ただし verdict が `go` で job が `pending` のものは候補に残す（判定済みでも未起動なら毎回 dispatch 対象。レビュー #2）。
4. 残りを `runs/<run_id>/candidates.tsv` に tmp → `mv` で置く（途中 timeout で欠けた snapshot を読ませない）。未判定が 0 件かつ pending も 0 件なら exit 1。

同時に sweep（§7）を走らせる。ここも Orca の結果を使うだけで GitHub は叩かない。

### 3.1 state と状態遷移

置き場所 `~/Library/Application Support/issue-autopilot/`。日付は `TZ=Asia/Tokyo` 固定。

| ファイル | 内容 | 消す? |
|---|---|---|
| `config` | `dispatch_enabled=false`、`max_per_run=2`、`max_active=3`、`max_per_day=4`、`cooldown_until=` | 人が編集 |
| `verdicts.tsv` | `repo#N  updatedAt  go/ask/skip  理由  decided_at` | 判定キャッシュ。issue が編集されたら再判定 |
| `jobs.tsv` | `repo#N  status  branch  worktreeId  operationId  launchHandle  prUrl  updated_at  note` | 1 issue 1 行。終端になっても残す |
| `launches.log` | `run_id  ts  repo#N  result` 追記のみ | 日次上限はこれで数える（GC で消えない。レビュー #6） |
| `board.tsv` | 最後にカードへ書いたコメント | 同じ内容を打ち直さない（`pr-dispatch.sh:31, 47-57`） |

job の状態: `pending → launching(operationId) → running(worktreeId, handle) → pr_opened(prUrl)` と、失敗側 `failed` / `needs_decision`。`pr_opened` だけが成功。`done <N> <url>` は worker が最後に呼ぶ。

`dispatch` の 1 回分（全部ロック内。ロックは `mkdir lock.d` + pid ファイル、pid が死んでいれば回収）:
1. `config` を読む。読めない・`dispatch_enabled` が無い・`false` → 何もしない（fail closed）。`cooldown_until` が未来なら何もしない。
2. 上限を数える: 今回分は `launches.log` の `run_id`、当日分は同ファイルの当日行、稼働中は `jobs.tsv` の `launching`/`running`。
3. 対象 1 件を取り、issue 単位の再確認（§4.4）を GitHub に 1 回問い合わせて行う。落ちたら verdict を破棄して `pending` を消す。
4. `launching` を書いてから `orca worktree create` → 戻り値で `running` に更新 → `orca agent launch` → handle を保存。途中で落ちたら次の run の sweep が `launching` 行を `orca worktree list` の branch 名で照合し、worktree があれば `running` に、無ければ `pending` に戻す。
5. `launches.log` に追記。

## 4. 判定（triage）と Needs decision

### 4.1 ルールで決まるもの（スクリプト）

| 条件 | 判定 |
|---|---|
| ラベル `security`（4）、`area: auth`（27）、`area: billing`（15） | ask |
| タイトルが `security —` / `infra —` / `本番` / `prd` / `prod` / `個人情報` / `PII` / `Secret` を含む | ask |
| issue に紐づく PR がある（§4.4 の照合） | ask（`pr-exists`） |

ask は dispatcher session を通さずスクリプトが直接ボードに出す。

### 4.2 LLM が見るもの（dispatcher session、`/issue-autopilot`）

未判定の候補を `updatedAt` 降順に 8 件まで。issue 本文・コメント・該当コードを読んで判定する。

go（全部満たす）:
- 期待する振る舞いが書いてあり、テストで表せる（仕様判断が要らない）。
- api リポで完結し、公開 API の形・DB スキーマ・`deploy/`・`config/` の secret を変えない（AGENTS.md:113 の 2 リポ跨ぎは ask）。
- 触るファイル 10 以下・差分 300 行以下・新しい依存なし（benny の bounded fix。数字は推測、§10 で直す）。
- Bug なら再現手順があるか、テストで再現できる見込みがある。

ask の理由コード: `spec` `scope` `auth` `billing` `security` `pii` `prod` `unclear` `owner` `pr-exists`。
skip（ボードに出さない）: 重複、既に直っている、`tracking`。

判定は `issue-autopilot.sh verdict <N> <go|ask|skip> "<理由>"` で書く。skill 自身には `orca worktree set` を打たせない。

### 4.3 Needs decision の出し方

worktree が無いので dispatcher のカードに集約する。

```
orca worktree set --worktree current --workspace-status needs-decision --unread \
  --comment "判断待ち 3: #9701 spec 招待期限の扱い / #9655 billing / #9602 scope infra-iac も要る" --json
```

1 件 `#<番号> <理由コード> <補足 20 字以内>`、`/` 区切り、1 行（`~/.claude/CLAUDE.md:117`）。人の答え方:
- `issue-autopilot.sh go <N>` — verdict を `go` にし job を `pending` にする（次の run で起動）。
- `issue-autopilot.sh skip <N>` — 以後見ない。
- issue を編集する → `updatedAt` が変わり再判定。

判定を GitHub issue に書かない。studio-api の issue は org の人に見える。自分の issue でも読み手は他人で、線引きの「他人の issue へのコメント」側に寄る（`~/.claude/CLAUDE.md:106-115`）。

### 4.4 着手直前の再確認（ownership gate、benny §3）

triage から起動までに状況が変わりうるので、`dispatch` と worker の両方で見直す。

- `dispatch`（スクリプト、GraphQL 1 回）: issue が open・author が自分・`no-agent` 無し・assignee に他人無し・`updatedAt` が verdict と一致・`closedByPullRequestsReferences` と timeline の CROSS_REFERENCED_EVENT に open/merged の PR が無い（`gh api graphql` で取れることを issue 9688 で確認）。1 つでも崩れたら `pending` を消し、verdict を破棄して次回の triage に戻す。
- worker（最初の編集前）: `gh issue view <N> --comments` を読み直し、「対応します」「PR を出した」の類があれば止めて `verdict ask owner`。

## 5. 流量制御

| 上限 | 初期値 | 数え方 |
|---|---|---|
| 1 run の起動 | 2 | `launches.log` の `run_id` |
| 同時稼働 | 3 | `jobs.tsv` の `launching`+`running`（codex 枠 4 を他セッションと共有するため） |
| 1 日の起動 | 4 | `launches.log` の当日行（`TZ=Asia/Tokyo`） |
| 1 run の triage | 8 | `candidates.tsv` を切る |
| worker 1 本の総時間 | 4 時間 | sweep が `running` の `updated_at` からの経過で判定（§7） |
| cooldown | 2 時間 | 直近 1 時間に 2 件以上 `failed` → `config` の `cooldown_until` を書く |

Claude の 5 時間上限はスクリプトから読めない（statusline が session 内の stdin JSON を読むだけ、`agents/claude/statusline.py`）。上限を控えめにし、止まった worker は sweep と cooldown で受ける。

codex 枠: worker は review の前に `pgrep -f 'codex exec' | wc -l` が 4 未満か見る（`orca-parallel-agent-pipeline.md:34`。`^` は付けない。絶対パス起動を数え漏らすため）。満杯なら 5 分おきに待つ。総時間 4 時間の中で空かなければ **PR を作らず** `issue-autopilot.sh fail <N> review-pending` を呼び、Needs decision に `codex 枠待ち: #N` を出す。レビュー無しの PR は作らない（`~/.claude/CLAUDE.md:70-71`）。ponytail: 枠の数え方は複数 worker が同時に 3 を見れば超えうる。同時稼働 3 の pilot では許容し、超えたら枠ディレクトリ方式（同 :35）にする。

## 6. 権限と安全策

権限モード: `~/.claude/settings.json:58` は `"defaultMode": "auto"`、Orca が起動する claude プロセスには `--permission-mode` が付かず、最近の worktree の transcript も `auto`。acceptEdits になった経路は未特定。プロジェクトの `.claude/settings.json` / `settings.local.json` の `defaultMode: auto` は効かない（https://code.claude.com/docs/en/permission-modes）ので、その案は捨てる。stage 0 で、実際に使う起動経路（`orca agent launch --surface chat`）で無害な prompt を流し、transcript の `permissionMode` を確認してから仕事の prompt を入れる。auto 以外なら `--surface terminal` を試し、それでも駄目なら止めて設計に戻る。`bypassPermissions` は使わない。auto モードは classifier が判定し、連続して block されると止まる（同 docs）。無人では止まったまま sweep が拾う。

push と merge:
- `dev`/`main` への commit と、`HEAD:dev` `HEAD:refs/heads/dev` を名指しする push は branch-guard が止める（`agents/claude/hooks/branch-guard.sh:66-78`、模擬入力で exit 2 を確認）。
- `gh pr merge`、`gh workflow run`、`gh release` はどの hook にも掛からない。worker の skill で禁じるのに加え、`agents/claude/settings.json` の deny に `Bash(gh pr merge *)` `Bash(gh workflow run *)` `Bash(gh release *)` を足す（提案。無人以外のセッションにも効くが、線引き上どのセッションもこれらを自動で打たない）。

秘密情報: deny は `.env` `.env.local` `.env.production` `.env.staging` `.env.testing` と鍵ファイル（`~/.claude/settings.json:59-72`）で、`.env*` 全部ではない。setup の `worktree-init.sh` は主 checkout の `.env` と `gcs_key.json` `firebase_key.json` `google_api_key.json` を新しい worktree にコピーする（`~/www/dev/app/scripts/worktree-init.sh:17, 67-70`）。つまり worker の worktree には主 checkout と同じ認証情報がある。`make` がコンテナに `.env` を渡すので外せない。やること: deny に `Read(//**/*_key.json)` を足す。Read の deny は Bash の `cat` までは覆わない（https://code.claude.com/docs/en/permissions#what-read-and-edit-rules-cover）ので、残りは auto モードの classifier と skill の禁止に頼る。ponytail: コンテナ/OS での隔離は pilot の範囲外。

worker の skill で禁じること: マージ、`gh pr ready`、他人の PR/issue へのコメント、Slack/メール、`deploy/` と `infra-iac`、本番の読み書き、migration の追加（見つけたら `fail <N> scope`）、`.env` と `*_key.json` の読み取り。benny §14 と同じ。

PR は `gh pr create --draft` で終わり。ready 化は人。pr-dispatch は非 draft だけ見る（`pr-dispatch.sh:104`）ので、人が ready にした時点から既存の流れに乗る。PR 本文は `/pr` skill の形（`agents/skills/pr/SKILL.md:38-61`）に従い、「検証:」の行に修正前に落ちたテスト名と修正後の結果を書き、`## 関連情報` に issue と「issue-autopilot による自動作成、Codex レビュー済み」を書く。

再現: benny は実 UI で独立に 2 回再現する（§7）。API では「失敗するテストを先に書いて赤を見る → 可能なら `/vasari:verify` か curl で 1 回」に置き換える（本設計での適応）。再現できなければ実装せず `fail <N> unclear` → Needs decision。

## 7. 失敗時と観測

worker の最初の手順（setup 待ち）: `./scripts/compose.sh ps --services --status running | grep -q '^php-fpm$'`（`Makefile:94-98` の guard-php と同じ）、`vendor/autoload.php`、`openapi/bundled/` の 3 つが揃うまで 60 秒おきに最長 20 分待つ。揃わなければ `orca terminal list --worktree current --json` で Setup タブの末尾を読み（`~/.claude-shared-memory/orca-worktree-setup-script.md:32-33`）、失敗した工程だけやり直す: `make up` → `make setup` → `cd openapi && pnpm run bundle:api`。それでも駄目なら `fail <N> setup` と Setup タブの最後の行を note に残す。

sweep（`candidates` の中、Orca の情報だけ）:

| 事象 | 検出 | 遷移 |
|---|---|---|
| `launching` のまま | `orca worktree list` に予約した branch がある/ない | `running` / `pending` |
| worktree が消えた | `running` の `worktreeId` が無い | `failed`（note: worktree 消失） |
| agent が `done`/`idle` で `pr_opened` でない | `orca worktree ps` の `agents[].state` | `failed` + Needs decision `終了したが PR なし: #N` |
| 600 秒停止・429（`orca-parallel-agent-pipeline.md:31`） | `working` で `updatedAt` が 2 時間動かない | `needs_decision` `停止: #N <経過>`。再開は人が Orca のタブで続きを指示 |
| 総時間超過 | `running` から 4 時間 | 同上 |
| 短時間に失敗が続く | 1 時間に `failed` 2 件 | `cooldown_until` を 2 時間先に |

worker 自身の失敗: テストが 2 回直しても赤 → push せず `fail <N> red <テスト名>`。`fail` は `jobs.tsv` を更新し、worker のカードを `needs-decision` + 1 行コメントにする。

観測:
- ログ `~/Library/Logs/issue-autopilot.log`（スクリプトが自分で追記。precheck の stdout の行き先は未確認）。
- `issue-autopilot.sh status` で `config` の有効値・jobs・当日の起動数を表にする。
- `orca automations runs --id <id>`（`skipped_precheck` もここ）。
- worker のカードは `--display-name "app: #N <title 30 字>"`（`~/.claude/CLAUDE.md:122`）、draft PR を出したら `in-review`（`agents/skills/pr/SKILL.md:35`）。
- コスト: `agents/claude/usage-report.py`。

## 8. 置き場所と登録

| もの | 場所 |
|---|---|
| スクリプト | `home/scripts/issue-autopilot.sh`（サブコマンド `candidates` `verdict` `dispatch` `done` `fail` `go` `skip` `status` `register`、`DRY_RUN=1`） |
| 設定 | `~/Library/Application Support/issue-autopilot/config`（無ければ `dispatch` は動かない。`register` が `dispatch_enabled=false` で雛形を置く） |
| automation 定義 | `register` が `orca automations list --json` を見て create / edit（冪等）。id を state に残す |
| triage の指示 | `agents/claude/skills/issue-autopilot/SKILL.md` |
| worker の指示 | `agents/claude/skills/issue-worker/SKILL.md`（人が手で `/issue-worker N` と打っても同じ） |
| deny の追加 | `agents/claude/settings.json`（§6） |
| 変更なし | `worktree-gc.sh`、`pr-dispatch.sh` |

配備: skill のリンク先は `${dotfilesDir}/agents/...` つまり主 checkout（`home/agent-skills.nix:14, 28`）。新しい skill は rebuild が要る（同 :11）。precheck のパスも主 checkout 固定。したがって **この worktree で足しただけでは動かず、main にマージ → 主 checkout を pull → `darwin-rebuild switch`** が stage 0 の最初。`run-from-main.nix:5` が避けている「レビュー前のスクリプトが無人で動く」問題は、主 checkout を main に置く運用で受け入れる。

## 9. 導入手順

| 段階 | やること | 確認すること |
|---|---|---|
| 0 | main にマージ、主 checkout を pull、rebuild。`ls -l ~/.claude/skills/issue-autopilot ~/.claude/skills/issue-worker` の実体と `git -C ~/www/personal/dotfiles rev-parse HEAD` を確認。`register`（`--disabled`、`dispatch_enabled=false`）。dispatcher 用 worktree を作る。`orca agent launch --surface chat` で無害 prompt を 1 本流し transcript の `permissionMode` を見る | `orca automations show` の定義。`permissionMode` が `auto`。`candidates` を手で回して `candidates.tsv` が妥当（既 worktree・tracking・他人 assignee が落ちている） |
| 1 | `orca automations run` を 2〜3 回 | `verdicts.tsv` の go/ask/skip と理由を全件読む。ask がカードに 1 行で出る。同じ issue を再判定しない。auth/billing が go になっていない。`status` に pending が溜まる |
| 2 | `dispatch_enabled=true`、`max_per_run=1`、手動 run を 2〜3 回 | `jobs.tsv` が `pending → launching → running → pr_opened` と進む。setup 待ちが効く（Setup タブと worker の最初の出力）。再確認で崩れた issue が pending から消える。失敗テスト → 修正 → 緑の証拠が PR 本文にある。PR が draft、branch が `issue-<N>-`、カード名・`in-review`。codex review が走った。sweep が `launching` の取りこぼしを直す |
| 3 | `orca automations edit --enabled`、上限は §5 の初期値、1 週間 | 1 日の起動数、放置された needs-decision、worker の平均時間、cooldown の発生、`usage-report.py`。人が ready にした後 pr-dispatch が拾う。マージ後に worktree-gc が片付ける |
| 4 | 上限を上げる／ルールを緩める | ask の理由コード別の件数。人が常に go にしているコードはルールから外す |

## 10. 未確定点と初回実験

1. 起動経路ごとの `permissionMode`（stage 0）。
2. precheck の cwd・PATH・`gh auth status`。precheck の最初でログに書く。
3. 重なった run: Orca が前の run の終了を待つかは docs に無い。ロックで二重起動は防ぐ。実験で挙動を見る。
4. Setup タブの JSON の形（終了コードが取れるか）。取れなければ §7 の 3 条件だけで判定する。
5. worker 1 本の所要時間と 600 秒停止の頻度。トップレベル session なら起きない見込み（`orca-parallel-agent-pipeline.md:39`）だが 10 分超は未確認。
6. 判定の閾値（10 ファイル・300 行）は推測。stage 1 の verdict で直す。
7. Sonnet の triage が甘ければ `--extra-agent-args="--model opus"`。
8. `linkedItems` の形。`linkedIssue` との差を stage 0 で `orca worktree list --json` から読む。

## 11. 変更するファイル

- 新規 `home/scripts/issue-autopilot.sh`
- 新規 `agents/claude/skills/issue-autopilot/SKILL.md`、`agents/claude/skills/issue-worker/SKILL.md`
- 変更 `agents/claude/settings.json`（deny 3 行 + `Read(//**/*_key.json)`）
- 本書 `docs/issue-autopilot-design.md`

## 12. 後回し

- 他リポ。`--repo` と slug を引数にすれば広がる。
- 自動 ready 化と pr-dispatch への接続（範囲を決めてから）。
- codex 枠の原子的な予約（同時稼働を 3 より上げるとき）。
- 認証情報の隔離（コンテナ/OS 側）。
- 5 時間上限の読み取り（API が出たら）。

