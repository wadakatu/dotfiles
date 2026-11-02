# issue-autopilot 設計書（改訂 3）

対象: Orca v1.4.246 / Claude Code 2.1.316 / studio-design/studio-api（Orca repo `app`、主 checkout `$HOME/www/dev/app`、default branch `dev`）。
書式は `docs/agent-gc-design.md` に倣う。出典は `path:line` か公式 docs の URL。推測には「推測」と書く。
改訂 3 は Codex の再レビュー（新規 10 件 + partly 9 件）を反映した。

## 1. 意図と決まっていること

自分が author の open issue を Orca の automation が拾い、issue ごとに worktree を作り、エージェントが **draft PR の作成まで** 進める。ready 化・マージは人。

決定済み（変えない）:
- ラベルでの opt-in はしない。author=@me の open issue は全部候補（今日 174 件）。opt-out は `no-agent` ラベルだけ。
- 実装前に「一人で進めてよいか」を判定し、曖昧・仕様判断・auth・個人情報・本番・課金・セキュリティは実装せず Needs decision に上げる。判定は worktree を作る前に行い、判断待ちの issue には worktree を作らない。
- 1 issue 1 PR。量は 1 日あたりで絞る。
- 最初は api リポだけ。

線引きはグローバル CLAUDE.md「委任の線引き」（`~/.claude/CLAUDE.md:87-119`）そのまま。新しく PR にするものは必ず Codex の実装レビューを通す（同 :70-71）。

Cursor pstack の benny（https://github.com/cursor/plugins/tree/main/pstack/automations/benny、skill 本文 https://raw.githubusercontent.com/cursor/plugins/main/pstack/automations/benny/skills/reproduce-and-fix-issues/SKILL.md）から借りる考え: 着手直前に誰かが持っていないかを見直す（ownership gate、§3）、修正の前に再現し症状を 2 回観測する（§7）、予算と範囲に収まるかを先に判定する（bounded fix）、修正前後の証拠を残す、draft PR のみでマージもデプロイもしない（§14）、triage と修正を分ける（README）。

## 2. 全体像

```
orca automations create --name issue-autopilot --trigger "0 */2 * * *" --provider claude \
  --workspace "path:<dispatcher worktree>" --workspace-mode existing \
  --extra-agent-args="--model sonnet --effort medium" \
  --precheck "$HOME/www/personal/dotfiles/home/scripts/issue-autopilot.sh candidates" --precheck-timeout 120 \
  --prompt "/issue-autopilot" --disabled
  │
  ├ precheck: candidates   ← スクリプト。GitHub 1 回 + Orca 2 回。「未判定」と「実行待ち」を別々に数え、両方 0 なら exit 1
  ▼
  dispatcher session (/issue-autopilot, Sonnet)       ← 未判定を triage。コードは書かない
  │   issue-autopilot.sh verdict <N> go|ask|skip "<1行>"  ← 判定キャッシュ。go は jobs に pending を作る
  │   issue-autopilot.sh dispatch                          ← pending を上限内で起動。ロック・予約・状態遷移はスクリプト
  ▼
  worker session per issue (/issue-worker <N>, Opus)  ← setup 完了待ち → 再確認 → 再現 → 修正 → テスト → codex review → draft PR
  │   issue-autopilot.sh done <N> <pr-url>              ← 成功の定義。これが無い終了は失敗
  ▼
  人が ready 化 → pr-dispatch / worktree-gc（既存）
```

| 段階 | 誰が | 根拠 |
|---|---|---|
| 候補抽出・重複除外・ルール判定・上限・ロック・状態遷移 | `issue-autopilot.sh`（LLM なし） | 機械的に決まるものは AI に任せない（`home/pr-dispatch.nix:7-8`） |
| 曖昧さ・範囲の判定（triage） | dispatcher session。Sonnet（`--extra-agent-args`、`orca automations create --help` 行 48。ユーザー設定の既定は opus `~/.claude/settings.json:3`） | issue と該当コードを読むだけ |
| 実装〜draft PR | worker session。Opus、effort high | 既存の開発フロー（`~/.claude/CLAUDE.md:65-68`） |
| 実装レビュー | `codex exec -C <wt> -s read-only review --base origin/dev` | 必須（同 :70-71）。枠 4 を共有（`~/.claude-shared-memory/orca-parallel-agent-pipeline.md:34`） |
| ready 後の CI / conflict / レビュー対応 | pr-dispatch（非 draft のみ `home/scripts/pr-dispatch.sh:104`） | 人が ready にした後 |
| マージ後の片付け | worktree-gc | `home/scripts/worktree-gc.sh:162-226` |

automation は 1 つ。benny の「triage と修正を分ける」は、判定（`verdicts`）と実行待ち（`jobs`）を別 state にし、`dispatch` が `config` の `dispatch_enabled` を毎回読むことで実現する（§8）。

dispatcher の実行場所は `app` の専用 worktree（表示名 `app: issue-autopilot`、ブランチは push しない）。判断待ちの集約カードも兼ねる（§4.3）。worker の worktree はこの worktree の子にする（`--parent-worktree`。`--no-parent` は使わない、`orca-parallel-agent-pipeline.md:12`）。

Orca automation を選んだ理由: run 履歴と terminal を Orca が持ち、`--precheck` で安い判定を前段に置ける（https://www.onorca.dev/docs/cli/automations、`--help` 行 44-46）。`orca automations run` は precheck を飛ばす（同 行 46）ので、skill の最初の手順でも `candidates` を呼ぶ。`--reuse-session` は extras と併用不可なので使わない（同 行 48）。

worker の起動（`dispatch` の中、ロック内、§3.2）:

```
orca worktree create --repo "path:$HOME/www/dev/app" --name "issue-$N-$slug" --branch "issue-$N-$slug" \
  --issue "$N" --base-branch origin/dev --parent-worktree "path:<dispatcher worktree>" --setup run --json
orca agent launch --agent claude --worktree "id:<worktreeId>" --model opus --effort high --surface chat \
  --prompt "/issue-worker $N" --json
```

- `path:~/…` は展開されず `repo_not_found`（`orca repo show` で確認）。`--branch` が無いと接頭辞 `wadakatu/` が付く（`orca worktree create --help` 行 49）。取られた名前には数字の接尾辞が付くので、戻り値の実ブランチ名と worktree id を保存する。
- `--agent` は付けない。repo の `setupAgentStartupPolicy: start-immediately` のため、付けると setup 完了前に動く（`orca repo show --json` の `.result.repo.hookSettings`）。
- 起動の返事が失われたら、エラーの `--retry-launch <operationId>` 付きで同じコマンドを再発行し、新規起動として再試行しない（`worktree create --help` 行 53、`agent launch --help` 行 27）。
- `--surface chat` は開けないと terminal に fallback する（`agent launch --help` 行 23）。`result.launch.outcome.kind` と `handle` を保存する（`worktree create --help` 行 54）。

## 3. 候補抽出と重複防止（`candidates`、precheck）

precheck の既定 timeout は 60 秒（`--help` 行 45）。issue ごとに GitHub を叩くと収まらないので、一括取得 3 回だけにし、issue 単位の照合は `dispatch` に回す。timeout は 120 秒。

1. `gh issue list -R studio-design/studio-api --author @me --state open -L 500 --json number,title,labels,updatedAt,assignees`。500 件なら打ち切りとみなして exit 1。
2. `orca worktree list --json` と `orca worktree ps --json`。`.ok != true` か `.result.truncated == true` なら exit 1（`worktree-gc.sh:75`）。branch は `refs/heads/` を外してから比べる（`pr-dispatch.sh:95` と同じ。実際の値は `refs/heads/wadakatu/…`）。
3. **未判定** を作る。次を除外:
   - ラベル `no-agent`、`tracking`、`Stale`。assignee に自分以外。
   - worktree がある: `repoId` が `app` の id（`141d1cc3-…`）で、`linkedIssue == N`、または `linkedItems[].url` が issue URL、または branch が `issue-<N>-` で始まる。
   - `jobs.tsv` に行がある（状態を問わない。pending も含む。再 triage は verdict 破棄時に行を消してから）。
   - `verdicts.tsv` に同じ `(repo#N, updatedAt)` の判定がある。
4. **実行待ち** は `jobs.tsv` の `pending` 行。未判定の除外処理は通さない。
5. 両方を `runs/<run_id>/candidates.tsv`（列: kind=untriaged|pending）に tmp → `mv` で置く。未判定 0 かつ実行待ち 0 なら exit 1。

同じ run で sweep（§7）を回す。Orca の結果だけで、GitHub は叩かない。

### 3.1 state

`~/Library/Application Support/issue-autopilot/`。日付は `TZ=Asia/Tokyo` 固定。

| ファイル | 内容 | 消す? |
|---|---|---|
| `config` | `dispatch_enabled=false` `max_per_run=2` `max_active=3` `max_per_day=4` `cooldown_until=` | 人が編集 |
| `verdicts.tsv` | `repo#N  updatedAt  go/ask/skip  理由  decided_at` | issue が編集されたら再判定 |
| `jobs.tsv` | `repo#N  status  branch  worktreeId  operationId  agentHandle  prUrl  started_at  updated_at  note` | 1 issue 1 行。終端でも残す |
| `launches.log` | `run_id  ts  repo#N  reserved/launched/failed` 追記のみ | 日次上限はこれ（GC で消えない） |
| `board.tsv` | 最後にカードへ書いたコメント | 同じ内容は打ち直さない（`pr-dispatch.sh:31, 47-57`） |
| `lock.d/` | `mkdir` ロック + pid。pid が死んでいれば回収 | |

**state を書く全サブコマンド（`verdict` `dispatch` `done` `fail` `go` `skip` と sweep）が同じロックを取り、取ってから読み直して書く。** tmp → `mv` は読み手のため、更新消失は防がない。

job の状態:

```
pending → launching(operationId → worktreeId → agentHandle) → running → pr_opened(prUrl)   成功は pr_opened だけ
                                                                  ↘ stalled（生存・枠を保持） → failed / pr_opened
                                                                  ↘ failed（停止を確認したもの）
```

`launching` は **agentHandle を保存するまで** 続ける。worktree ができただけでは `running` にしない（agent を起動するのは `--agent` か `agent launch`、`worktree create --help` 行 52-53）。

### 3.2 `dispatch` の 1 回分（全部ロック内）

1. `config` を読む。読めない・`dispatch_enabled` が無い・`false`・`cooldown_until` が未来 → 何もしない（fail closed）。
2. 上限: 今回分 = `launches.log` の `run_id`、当日分 = 当日の `reserved` 行（失敗も枠を使う）、稼働中 = `jobs.tsv` の `launching` + `running` + `stalled`。
3. `pending` を 1 件取り、再確認（§4.4）を GraphQL 1 回で行う。結果で分岐（PR あり → `ask pr-exists`、版が変わった → 再判定、通信失敗・`hasNextPage=true` → pending のまま今回は飛ばす）。
4. `launches.log` に `reserved` を追記し、`launching` を書いてから `orca worktree create` → `worktreeId` と実 branch を書く → `orca agent launch` → `agentHandle` を書いて `running`、`launches.log` を `launched` に。
5. 途中で落ちたら次の run の sweep が直す（§7）。

## 4. 判定（triage）と Needs decision

### 4.1 ルールで決まるもの（スクリプト）

| 条件 | 判定 |
|---|---|
| ラベル `security`（4）、`area: auth`（27）、`area: billing`（15） | ask |
| タイトルが `security —` / `infra —` / `本番` / `prd` / `prod` / `個人情報` / `PII` / `Secret` を含む | ask |
| issue に紐づく PR がある（§4.4） | ask `pr-exists`（verdict に保存し、再 triage させない） |

ask は dispatcher session を通さずスクリプトが直接ボードに出す。

### 4.2 LLM が見るもの（dispatcher session、`/issue-autopilot`）

未判定を `updatedAt` 降順に 8 件まで。issue 本文・コメント・該当コードを読む。

go（全部満たす）:
- 期待する振る舞いが書いてあり、テストで表せる。
- api リポで完結し、公開 API の形・DB スキーマ・`deploy/`・secret を変えない（2 リポ跨ぎは ask、`~/www/dev/app/AGENTS.md:113`）。
- 触るファイル 10 以下・差分 300 行以下・新しい依存なし（bounded fix。数字は推測、§10）。
- Bug なら再現手順があるか、テストで再現できる見込みがある。

ask の理由コード: `spec` `scope` `auth` `billing` `security` `pii` `prod` `unclear` `owner` `pr-exists`。skip: 重複、既に直っている。

`issue-autopilot.sh verdict <N> <go|ask|skip> "<理由>"` で書く。skill 自身に `orca worktree set` は打たせない。

### 4.3 Needs decision の出し方

worktree が無いので dispatcher のカードに集約する。

```
orca worktree set --worktree current --workspace-status needs-decision --unread \
  --comment "判断待ち 3: #9701 spec 招待期限の扱い / #9655 billing / #9602 pr-exists PR #9700" --json
```

1 件 `#<番号> <理由コード> <補足 20 字以内>`、`/` 区切り、1 行（`~/.claude/CLAUDE.md:117`）。人の答え方: `issue-autopilot.sh go <N>`（verdict を go、job を pending）、`issue-autopilot.sh skip <N>`、issue を編集（`updatedAt` が変わり再判定）。

判定を GitHub issue には書かない。読み手は org の他人で、線引きの「他人の issue へのコメント」側に寄る（`~/.claude/CLAUDE.md:106-115`）。

### 4.4 着手直前の再確認（ownership gate、benny §3）

`issue-autopilot.sh recheck <N>` を `dispatch` と worker の両方が呼ぶ。GraphQL 1 回で issue の state・author・labels・assignees・updatedAt・`closedByPullRequestsReferences`・timeline の CROSS_REFERENCED_EVENT（PR のみ）を取る（9688 で空の結果は確認。非空は stage 2 で見る）。

| 結果 | 遷移 |
|---|---|
| closed / author が自分でない / `no-agent` / 他人の assignee | job を消し verdict を `skip` に |
| open か merged の PR がある | job を消し verdict を `ask pr-exists`、ボードへ |
| `updatedAt` が verdict と違う | job と verdict を消す（次回 triage） |
| 通信失敗、どれかの connection が `hasNextPage=true` | 何もしない（pending のまま。worker なら 5 分後に 1 回だけ再試行、駄目なら `fail <N> recheck`） |

worker は setup 待ち（§7）の後、最初の編集前に `recheck` を呼び、さらに `gh issue view <N> --comments` を読んで「対応します」「PR を出した」の類があれば `fail <N> owner`。

## 5. 流量制御

| 上限 | 初期値 | 数え方 |
|---|---|---|
| 1 run の起動 | 2 | `launches.log` の `run_id` |
| 同時稼働 | 3 | `launching` + `running` + `stalled`。`stalled` は生存中なので枠を離さない |
| 1 日の起動 | 4 | `launches.log` の当日 `reserved` |
| 1 run の triage | 8 | |
| worker の時間 | 4 時間で通知（停止はしない） | §7 |
| cooldown | 2 時間 | 直近 1 時間に `failed` 2 件で `config` の `cooldown_until` を書く |

4 時間は通知閾値で、強制停止ではない。止めるのは人（タブを閉じる）か worker 自身。枠はエージェントの停止を sweep が確認するまで保持する。

Claude の 5 時間上限はスクリプトから読めない（`agents/claude/statusline.py` は session 内の stdin JSON を読むだけ）。上限を控えめにし、sweep と cooldown で受ける。

codex 枠: worker は review の前に `pgrep -f '[c]odex exec' | wc -l` が 4 未満か見る（`orca-parallel-agent-pipeline.md:34`。括弧で自分の shell を数えない、`^` は付けない）。満杯なら 5 分おきに待つ。4 時間までに空かなければ **PR を作らず** `fail <N> review-pending`。レビュー無しの PR は作らない（`~/.claude/CLAUDE.md:70-71`）。ponytail: 同時に 3 を見れば超えうる。稼働 3 の pilot では許容し、上げるとき枠ディレクトリ方式（同 :35）。

## 6. 権限と安全策

権限モード: `~/.claude/settings.json:58` は `"defaultMode": "auto"`、Orca 起動の claude に `--permission-mode` は付かず、最近の transcript も `auto`。acceptEdits の経路は未特定。プロジェクト側 `.claude/settings*.json` の `defaultMode: auto` は効かない（https://code.claude.com/docs/en/permission-modes）。stage 0 で実際の経路（`orca agent launch --surface chat`）に無害な prompt を流し、transcript の `permissionMode` を確認してから仕事の prompt を入れる。auto 以外なら `--surface terminal`、それでも駄目なら止める。`bypassPermissions` は使わない。

push と merge:
- branch-guard は保護ブランチ上の commit/push と `HEAD:dev` 名指しの push を止める（`agents/claude/hooks/branch-guard.sh:66-78`）が、作業ブランチから `git push origin HEAD:refs/heads/dev` は通る（宛先検査 :76 が `refs/heads/` を見ない。模擬入力で exit 0）。**stage 0 の前提として別 PR で直す**: 宛先検査に `refs/heads/` 省略可を足し、作業ブランチを cwd にした回帰確認を付ける。
- `gh pr merge`、`gh workflow run`、`gh release` はどの hook にも掛からない。`agents/claude/settings.json` の deny に `Bash(gh pr merge *)` `Bash(gh workflow run *)` `Bash(gh release *)` を足す（全セッションに効くが、線引き上どのセッションも自動では打たない）。

秘密情報: deny は `.env` `.env.local` `.env.production` `.env.staging` `.env.testing` と鍵（`~/.claude/settings.json:59-72`）。setup の `worktree-init.sh` は主 checkout の `.env` と `gcs_key.json` `firebase_key.json` `google_api_key.json` を新 worktree にコピーする（`~/www/dev/app/scripts/worktree-init.sh:17, 67-70`）ので worker の worktree には主 checkout と同じ認証情報がある。`make` がコンテナに `.env` を渡すので外せない。やること: deny に `Read(//**/*_key.json)` を足す。Read の deny は `cat` `head` `tail` `sed` `tee` とリダイレクトにも効くが、ディレクトリへの `grep -r` や Python/Node の子プロセスからの読み取りには効かない（https://code.claude.com/docs/en/permissions#what-read-and-edit-rules-cover）。残りは auto モードの classifier と skill の禁止。pilot に追加の隔離基盤は要らない。

worker の skill で禁じること: マージ、`gh pr ready`、他人の PR/issue へのコメント、Slack/メール、`deploy/` と `infra-iac`、本番の読み書き、migration の追加（`fail <N> scope`）、`.env` と `*_key.json` の読み取り（benny §14）。

PR は `gh pr create --draft` で終わり。本文は `/pr` skill の形（`agents/skills/pr/SKILL.md:38-61`）。「検証:」に修正前に落ちたテスト名と修正後の結果、`## 関連情報` に issue と「issue-autopilot による自動作成、Codex レビュー済み」。draft のままなので pr-dispatch は触らず（`pr-dispatch.sh:104`）、人が ready にした時点から既存の流れに乗る。

再現: benny は実 UI で独立に 2 回再現する（§7）。API では「失敗するテストを先に書いて赤を見る → 可能なら `/vasari:verify` か curl で 1 回」に置き換える（本設計の適応）。再現できなければ `fail <N> unclear`。

## 7. 失敗時と観測

**setup 完了待ち（worker の最初の手順）**: 完了の印は setup script 自身が最後に出す `Orca setup done:` の行（`orca repo show --json` の `hookSettings.scripts.setup`。`set -euo pipefail` なので全工程成功時だけ出る）。`orca terminal list --worktree current --json` で Setup タブを見つけ、出力末尾にこの行が出るまで 60 秒おきに最長 20 分待つ。`openapi/bundled/` の存在は使わない（`bundle:api` は 5 本を順に作る、`~/www/dev/app/openapi/package.json:13`）。
再試行: 印が無く、Setup タブの `lastOutputAt` が 5 分以上動かない（推測: 終了の代わり）ときだけ 1 回、**同じ script をそのまま** 流す: `orca repo show --repo "path:$HOME/www/dev/app" --json | jq -r '.result.repo.hookSettings.scripts.setup' | ORCA_WORKTREE_PATH="$PWD" bash`。出力が動いている間は重ねない。それでも印が出なければ `fail <N> setup` と末尾の行を note に。

**sweep（`candidates` の中、Orca の情報だけ、ロック内）**:

| 状態 | 検出 | 遷移 |
|---|---|---|
| `launching`、worktreeId 無し | `orca worktree list` に予約 branch（`refs/heads/` 除去後、接尾辞も許す）がある / ない | worktreeId を書く / `pending` に戻し `launches.log` を `failed` |
| `launching`、worktreeId あり、agentHandle 無し | `orca worktree ps` の `agents[]` が空 / ある | `orca agent launch` をやり直す（枠は既に使用中） / handle を書いて `running` |
| `running`/`stalled`、worktree が無い | | `failed`（note: worktree 消失） |
| `running`、agent が `done`/`idle` で `pr_opened` でない | `agents[].state` | `failed` + Needs decision `終了したが PR なし: #N` |
| `running`、`working` のまま `updatedAt` が 2 時間動かない（600 秒停止・429、`orca-parallel-agent-pipeline.md:31`）、または `started_at` から 4 時間 | | `stalled` + Needs decision `停止: #N <経過>`。枠は保持。再開は人が Orca のタブで続きを指示 |
| `stalled`、agent が `done`/`idle` | | `failed`（`done <N>` 済みなら `pr_opened`） |
| 1 時間に `failed` 2 件 | | `cooldown_until` を 2 時間先に |

worker 自身の失敗: テストが 2 回直しても赤 → push せず `fail <N> red <テスト名>`。`fail` は job を `failed` にし、worker のカードを `needs-decision` + 1 行コメントにする。

観測: ログ `~/Library/Logs/issue-autopilot.log`（スクリプトが追記。precheck の stdout の行き先は未確認）、`issue-autopilot.sh status`（config の有効値・jobs・当日の起動数）、`orca automations runs --id <id>`、worker のカード `--display-name "app: #N <title 30 字>"`（`~/.claude/CLAUDE.md:122`）と draft PR 後の `in-review`（`agents/skills/pr/SKILL.md:35`）、コストは `agents/claude/usage-report.py`。

## 8. 置き場所と登録

| もの | 場所 |
|---|---|
| スクリプト | `home/scripts/issue-autopilot.sh`（`candidates` `verdict` `dispatch` `recheck` `done` `fail` `go` `skip` `status` `register`、`DRY_RUN=1`） |
| 設定 | `~/Library/Application Support/issue-autopilot/config`（無ければ `dispatch` は動かない。`register` が `dispatch_enabled=false` で雛形を置く） |
| automation 定義 | `register` が `orca automations list --json` を見て create / edit（冪等、§2 の引数）。id を state に残す |
| triage の指示 | `agents/claude/skills/issue-autopilot/SKILL.md` |
| worker の指示 | `agents/claude/skills/issue-worker/SKILL.md`（人が `/issue-worker N` と打っても同じ） |
| deny の追加 | `agents/claude/settings.json`（§6） |
| branch-guard の修正 | 別 PR（§6） |
| 変更なし | `worktree-gc.sh`、`pr-dispatch.sh` |

配備: skill のリンク先は `${dotfilesDir}/agents/…` つまり主 checkout（`home/agent-skills.nix:14, 28`）で、新しい skill は rebuild が要る（同 :11）。precheck のパスも主 checkout。**main にマージ → 主 checkout を pull → `darwin-rebuild switch`** が stage 0 の最初。

## 9. 導入手順

| 段階 | やること | 確認すること |
|---|---|---|
| 0 | branch-guard の修正 PR をマージ。本設計の PR をマージ、主 checkout を pull、rebuild。`ls -l ~/.claude/skills/issue-autopilot ~/.claude/skills/issue-worker` と `git -C ~/www/personal/dotfiles rev-parse HEAD`。dispatcher 用 worktree を作る。`register`（`--disabled`、`dispatch_enabled=false`）。`orca agent launch --surface chat` で無害 prompt を 1 本流す | `orca automations show` の引数（model sonnet を含む）。transcript の `permissionMode` が `auto`。`candidates` を手で回して untriaged/pending の 2 群が妥当。`orca worktree list --json` の `linkedItems[].url` と branch の形 |
| 1 | `orca automations run` を 2〜3 回 | `verdicts.tsv` の go/ask/skip と理由を全件読む。ask がカードに 1 行で出る。同じ issue を再判定しない。auth/billing が go になっていない。`status` に pending が溜まり、次の run の候補にも残る |
| 2 | `dispatch_enabled=true`、`max_per_run=1`、手動 run を 2〜3 回 | `jobs.tsv` が `pending → launching(worktreeId → agentHandle) → running → pr_opened`。`launches.log` に reserved → launched。worker が `Orca setup done:` を待ってから動く。`recheck` で PR ありが `ask pr-exists` になる（PR を手で紐づけて試す）。失敗テスト → 修正 → 緑の証拠が PR 本文にある。PR が draft、branch が `issue-<N>-`。codex review が走った。途中で `kill` して sweep が `launching` を直す |
| 3 | `orca automations edit --enabled`、上限は §5、1 週間 | 1 日の起動数、`stalled` の数と枠の保持、cooldown の発生、`usage-report.py`。人が ready にした後 pr-dispatch が拾い、マージ後に worktree-gc が片付ける |
| 4 | 上限を上げる／ルールを緩める | ask の理由コード別の件数 |

## 10. 未確定点と初回実験

1. 起動経路ごとの `permissionMode`（stage 0）。
2. precheck の cwd・PATH・`gh auth status`（precheck の最初でログに書く）。
3. 重なった run の扱いは docs に無い。ロックで二重起動は防ぎ、挙動を見る。
4. Setup タブの「終了」が JSON から取れるか（`orca terminal list --json` の列は `lastOutputAt` `preview` など。終了コードは無い）。取れなければ §7 の 5 分無出力で代用。
5. worker 1 本の所要時間と 600 秒停止の頻度（10 分超は未確認、`orca-parallel-agent-pipeline.md:39`）。
6. 判定の閾値は推測。stage 1 で直す。
7. Sonnet の triage が甘ければ `--extra-agent-args="--model opus --effort medium"`。
8. `recheck` の非空ケース（PR が紐づく issue）。

## 11. 変更するファイル

- 新規 `home/scripts/issue-autopilot.sh`
- 新規 `agents/claude/skills/issue-autopilot/SKILL.md`、`agents/claude/skills/issue-worker/SKILL.md`
- 変更 `agents/claude/settings.json`（deny 3 行 + `Read(//**/*_key.json)`）
- 別 PR `agents/claude/hooks/branch-guard.sh`（`refs/heads/` 対応 + 回帰確認）
- 本書 `docs/issue-autopilot-design.md`

## 12. 後回し

- 他リポ。`--repo` と slug を引数にすれば広がる。
- 自動 ready 化と pr-dispatch への接続。
- codex 枠の原子的な予約（稼働 3 より上げるとき）。
- 認証情報の隔離（コンテナ/OS 側）。
- 5 時間上限の読み取り。

### Critical Files for Implementation
- /Users/wadakatu/www/personal/dotfiles/home/scripts/issue-autopilot.sh（新規。候補抽出・判定記録・ロック付き dispatch・recheck・sweep・登録）
- /Users/wadakatu/www/personal/dotfiles/home/scripts/pr-dispatch.sh（state TSV・board()・GraphQL 一括取得・`refs/heads/` 除去 :95 の手本）
- /Users/wadakatu/www/personal/dotfiles/home/scripts/memory-maintenance.sh（`pending`/`creating` の回復と日次上限の手本 :795-812）
- /Users/wadakatu/www/personal/dotfiles/agents/claude/hooks/branch-guard.sh（stage 0 前提の修正箇所 :76）
- /Users/wadakatu/www/dev/app/scripts/worktree-init.sh（setup がコピーする認証情報と要求の一次情報）
