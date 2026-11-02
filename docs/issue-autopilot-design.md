# issue-autopilot 設計書

対象: Orca v1.4.246 / Claude Code 2.1.316 / studio-design/studio-api（Orca repo `app`、主 checkout `~/www/dev/app`、default branch `dev`）。
書式と節立ては `docs/agent-gc-design.md` に倣う。出典は `path:line` か公式 docs の URL。推測には「推測」と書く。

## 1. 意図と決まっていること

自分が author の open issue を、Orca の automation が拾い、issue ごとに worktree を作り、エージェントが PR 作成まで進める。マージは人。

決定済み（変えない）:
- ラベルでの opt-in はしない。author=@me の open issue は全部候補。opt-out は `no-agent` ラベルだけ。
- 実装前に「一人で進めてよいか」を判定し、曖昧・仕様判断・auth・個人情報・本番・課金・セキュリティは実装せず Needs decision に上げる。worktree を作る前に判定するので、判断待ちの issue には worktree を作らない。
- PR は 1 issue 1 PR、まとめない。量は 1 日あたりで絞る。
- 最初は api リポだけ。

線引きはグローバル CLAUDE.md の「委任の線引き」（`~/.claude/CLAUDE.md:87-119`）そのまま: 自分のブランチへの push と PR 作成は聞かずに進める、本番反映・仕様判断・他人の PR/issue へのコメント・Slack 等の発信は止まる。

Cursor pstack の benny（https://github.com/cursor/plugins/tree/main/pstack/automations/benny）から借りる考え: 修正の前に再現する、症状を 2 回観測する、誰かが着手済みなら手を出さない（ownership gate）、修正が予算と範囲に収まるかを先に判定する（bounded fix）、修正前後の証拠を残す、PR は draft でマージもデプロイもしない、triage と修正を分ける。借りた箇所にはそのつど出典を書く。

## 2. 全体像

```
Orca automation "issue-autopilot"  (--trigger "0 */2 * * *", --provider claude, --workspace path:<dispatcher worktree> --workspace-mode existing)
  │ precheck: issue-autopilot.sh candidates     ← スクリプト。候補が 0 なら exit 1 で run を飛ばす
  ▼
  dispatcher session (/issue-autopilot skill, Sonnet)   ← triage だけ。コードは書かない
  │  issue-autopilot.sh verdict <N> go|ask|skip "<1行>"   ← 判定を state に書く。ask はボードへ
  │  issue-autopilot.sh dispatch <N>                       ← 上限内なら worktree 作成 + worker 起動
  ▼
  worker session per issue (/issue-worker <N>, Opus)     ← 再現 → 修正 → テスト → codex review → draft PR
  ▼
  pr-dispatch / worktree-gc（既存）                        ← PR 以降の CI 修正・レビュー対応・片付け
```

役割分担:

| 段階 | 誰が | 根拠 |
|---|---|---|
| 候補抽出・重複除外・ルール判定・上限 | スクリプト `issue-autopilot.sh`（LLM なし） | 材料が機械的に決まるものは AI に任せない方針は pr-dispatch と同じ（`home/pr-dispatch.nix:7-8`） |
| 曖昧さ・範囲の判定（triage） | dispatcher session。モデルは Sonnet、effort medium | issue 本文と該当コードを読むだけ。安く、1 run で 5〜10 件見る |
| 実装〜PR | worker session。Opus、effort high | いまの開発フロー（Opus 実装 → Codex レビュー）と同じ |
| 実装レビュー | `codex exec -s read-only review --base origin/dev` | 既存の運用。枠 4 を共有（`~/.claude-shared-memory/orca-parallel-agent-pipeline.md:34`） |
| PR 後の CI / conflict / レビュー対応 | pr-dispatch（既存） | `home/scripts/pr-dispatch.sh:188-194` |
| マージ後の worktree 削除 | worktree-gc（既存） | `home/scripts/worktree-gc.sh:162, 226` |

triage と修正を分けるのは benny と同じ構成（README の "triage" と "reproduce-and-fix" の 2 automation）。ここでは automation は 1 つにし、分離は「判定は state に残り、`dispatch` はスクリプトの上限ゲートを通らないと動かない」で実現する。段階導入（§9）では `DISPATCH=0` で triage だけ回す。

dispatcher の実行場所は `app` の専用 worktree `app/issue-autopilot`（ブランチは push しない。コードを触らない）。`--workspace <selector> --workspace-mode existing` で固定する（`orca automations create --help` 行 24）。判断待ちの issue に worktree を作らない代わりに、このカードのコメントに集約する（§4）。

Orca automation を選んだ理由: Orca が run 履歴と terminal を持ち、`--precheck` で安いスクリプト判定を前段に置ける（docs: https://www.onorca.dev/docs/cli/automations、`orca automations create --help` 行 44-46）。launchd にしなかったのは、同じ機能を自前で持つことになるため。ただし `orca automations run` は precheck を飛ばす（同 行 46）ので、手動実行の時は skill 側でも `candidates` を呼ぶ。

worker 起動は `orca worktree create --repo path:~/www/dev/app --name issue-<N>-<slug> --issue <N> --base-branch origin/dev --agent claude --model opus --effort high --surface chat --setup run --prompt "/issue-worker <N>" --json`。`--issue` でカードが issue に紐づく、`--surface` で表示面を選べる、並列パイプラインで実績がある（`orca-parallel-agent-pipeline.md:14-15`）の 3 点で `orca orchestration worker-start` より優先する。worker-start は `--issue` が無く、配置が設定依存で、10 分超の worker は未確認（同 :37-39）。`--repo` は主 checkout を指すこと、事前に `git fetch origin`（同 :15）。setup は `run`（`make worktree-init; make build; make setup; …` が Orca の repo 設定 `setupRunPolicy: run-by-default` で走る）。

## 3. 候補抽出と重複防止（`issue-autopilot.sh candidates`）

1. `gh issue list -R studio-design/studio-api --author @me --state open -L 200 --json number,title,labels,updatedAt,assignees`（今日の時点で 174 件）。
2. 除外（ルール、LLM なし）:
   - ラベル `no-agent`（opt-out）、`tracking`（12 件）、`Stale`（3 件）。
   - assignee に自分以外がいる → benny の ownership gate（`skills/reproduce-and-fix-issues/SKILL.md`「someone has claimed the fix → stop」）。
   - 既に worktree がある: `orca worktree list --json` の `.result.worktrees[].linkedIssue == N`、または branch 名が `issue-<N>-` で始まる。
   - 既に PR がある: `gh pr list -R <slug> --state open --search "author:@me <N> in:body"`、`closes #N`/`#N` のいずれか。open PR があれば skip、merged/closed なら issue が閉じていないので人の判断（ask）。
   - 他人の PR が紐づく（timeline の CROSS_REFERENCED_EVENT に他人の open PR）→ skip（ownership gate）。
   - state `verdicts.tsv` に同じ `(number, updatedAt)` の判定がある → 再判定しない（issue が編集されたら再判定）。
3. 残りを `candidates.tsv`（number, title, labels, updatedAt, rule-hint）に書く。0 行なら exit 1。

前回の残りの扱い:
- 前回 dispatch した worktree は `dispatched.tsv`（number, path, created_at）に残す。`orca worktree ps --json` で `agents[].state != done` のものは「稼働中」に数える（判定関数は `worktree-gc.sh:79` の `agents_busy` と同じ）。`.result.truncated == true` なら安全側で何も起動しない（`worktree-gc.sh:75` と同じ条件）。
- worktree が消えていた（worktree-gc が片付けた）行は state から落とす。
- 2 時間以上 `working` のまま `updatedAt` が動かない worker は「詰まり」として §7 へ。

実行間隔 2 時間は、worker 1 本が 30〜90 分（benny の `fix_minutes 90` と同程度、`templates/configuration.example.yaml`）で、前回分が終わってから次を見る程度の粗さにするため。重なった run の並列性は Orca docs に無いので、state ファイルに `flock` 相当（`mkdir` ロック）を置き、二重 dispatch を防ぐ。

## 4. 判定（triage）と Needs decision の書き方

### 4.1 ルールで決まるもの（スクリプト、`rule-hint`）

| 条件 | 判定 |
|---|---|
| ラベル `security`（4 件）、`area: auth`（27）、`area: billing`（15） | ask |
| タイトルが `security —` / `infra —` / `本番` / `prd` / `prod` / `個人情報` / `PII` / `Secret` を含む | ask |
| 本文に `deploy/`, `infra-iac`, `Secret Manager` の変更が要ると書いてある | ask（AGENTS.md:113 の 2 リポ跨ぎ） |

ask は dispatcher session を通さずスクリプトが直接 Needs decision に上げる。安く、ブレない。

### 4.2 LLM が見るもの（dispatcher session、`/issue-autopilot` skill）

残りの候補ごとに issue 本文と該当コードを読み、次の順で判定する。

go の条件（全部満たす）:
- 期待する振る舞いが issue に書いてあり、受け入れ条件かテストで表せる（仕様判断が要らない）。
- 変更が api リポで完結し、公開 API の形（レスポンスのキー・ステータス）と DB スキーマを変えない。変えるなら ask。
- 見積りが「触るファイル 10 以下・差分 300 行以下・新しい外部依存なし」に収まる（benny の bounded-fix: "fits fix budget" `skills/reproduce-and-fix-issues/SKILL.md`。数字は推測、初回実験で直す）。
- Bug なら再現手順が書いてあるか、テストで再現できる見込みがある。

ask の理由コード（コメントの 1 行に入れる）: `spec`（仕様判断）、`scope`（大きすぎ/複数リポ）、`auth` `billing` `security` `pii` `prod`（領域）、`unclear`（本文が足りない）、`owner`（他人が着手）。

skip（ボードに出さない。state にだけ残す）: 重複 issue、既に直っている（コードを見て確認）、`tracking`。

判定は `issue-autopilot.sh verdict <N> go|ask|skip "<理由 1 行>"` で state に書く。skill 自身に `orca worktree set` を打たせない。

### 4.3 Needs decision の出し方

worktree が無いので、dispatcher の worktree のカードに集約する。

```
orca worktree set --worktree current --workspace-status needs-decision --unread \
  --comment "判断待ち <k> 件: #9701 spec 期限切れ招待の扱いが未定 / #9655 billing / #9602 scope infra-iac も要る" --json
```

形式は 1 件 `#<番号> <理由コード> <補足 20 字以内>`、`/` 区切り。`--comment` は 1 行（CLAUDE.md:117）。コメントの全文は `board.tsv` に持ち、同じ内容なら打ち直さない（`pr-dispatch.sh:31, 47-57` と同じ）。人が答える手段:
- `issue-autopilot.sh go <N>` — 判定を上書きして次の run で dispatch。
- `issue-autopilot.sh skip <N>` — 以後見ない。
- issue を編集する（updatedAt が変わり再判定）。

判定を GitHub issue に書くか: 書かない。studio-api の issue は org の人に見える。「AI が auth だから保留した」と残すのは他人への発信に当たり、線引き（CLAUDE.md:106-115）の「他人の issue へのコメント」側に寄る。自分の issue でも読む人は他人。state ファイルとボードに閉じる。

## 5. 流量制御

| 上限 | 値（初期） | 実装 |
|---|---|---|
| 1 run の dispatch | 2 | `dispatch` が `dispatched.tsv` の今回分を数える。pr-dispatch の `MAX_LAUNCHES=3`（`pr-dispatch.sh:33`）に倣う |
| 同時稼働の autopilot worktree | 3 | `dispatched.tsv` ∩ `orca worktree ps` で agent が `done` でない数。codex 枠 4 をほかのセッションと共有するため（`orca-parallel-agent-pipeline.md:34`） |
| 1 日の dispatch | 4 | `dispatched.tsv` の当日行。memory-maintenance の `MAX_PR_PER_DAY=5`（`memory-maintenance.sh:45`）と同じ発想 |
| 1 run の triage 件数 | 8 | `candidates.tsv` を updatedAt 降順で切る |

Claude の 5 時間上限: スクリプトから読む API は見つからなかった（statusline が session 内の stdin JSON `rate_limits` を読むだけ、`agents/claude/statusline.py`）。対策は上限を控えめにすることと、429 で止まった worker を §7 で拾うこと。推測: `dispatch` の前に `ps` で `claude` プロセス数を数え、対話セッションが 4 以上あるときは dispatch を 1 に落とす程度の粗い制御で足りる。

codex 枠: worker が review の前に `pgrep -f '^codex exec' | wc -l` が 4 未満か見る（同 :34）。満杯なら 5 分ずつ最大 30 分待ち、それでも空かなければ review を飛ばし PR 本文に「Codex レビュー未実施」と書く。

## 6. 権限と安全策

権限モード: 事実として `~/.claude/settings.json:58` は `"defaultMode": "auto"`、Orca が起動する claude プロセスには `--permission-mode` が付かず、最近の Orca worktree の transcript には `"permissionMode":"auto"` が多数残っている。acceptEdits になった原因は未特定（推測: chat surface か SDK 経由の起動で別の既定が使われる）。§10 の初回実験で worker の transcript の `permissionMode` を見る。Orca automation の `--extra-agent-args` は model/effort/add-dir 以外を拒む（`--help` 行 48）ので、automation 側からは直せない。直すなら `~/.claude/settings.json` の `defaultMode` か、worktree の `.claude/settings.local.json`（gitignore 済み、`~/www/dev/app/.gitignore:50`）を setup で置く。auto モードの中身は https://code.claude.com/docs/en/permission-modes（classifier が判断、3 連続/20 回の block で停止）。`bypassPermissions` は使わない。

既存の仕組みで担保されるもの:
- `dev`/`main` への commit/push は branch-guard が止める（`agents/claude/hooks/branch-guard.sh:66-78`、`settings.json:230`）。worker は `issue-<N>-<slug>` ブランチだけに push。
- 文章で質問して止まるのを question-guard が差し戻し、AskUserQuestion か Needs decision に誘導（`agents/claude/hooks/question-guard.sh:3-7`、`settings.json:262`）。
- `.env*`・鍵・`~/.ssh`・`~/.config/gh` の読み取りは deny（`~/.claude/settings.json` permissions.deny）。

worker の prompt（`/issue-worker` skill）で禁じること: マージ、`gh pr ready` 以外の PR 状態変更、他人の PR/issue へのコメント、Slack/メール、`deploy/` と `infra-iac` の変更、本番の読み書き、migration の追加（ask に戻す）。benny の "never merge or deploy, draft PR only"（`README.md`）と同じ。

PR は `gh pr create --draft`。worker が「テスト緑・codex 指摘対応済み・`/vasari:verify` 済み」を自分で確認したら `gh pr ready` にして pr-dispatch に引き継ぐ（pr-dispatch は非 draft だけ見る、`home/pr-dispatch.nix:3`）。段階導入の間は draft のまま止める。PR 本文は `/pr` skill の形式（`agents/skills/pr/SKILL.md:25-35`）に「再現の証拠（修正前に失敗したテスト名と出力）」「修正後の証拠」「Codex レビューの要約」「自動作成（issue-autopilot）」を足す。再現は benny の "observe the symptom twice before fixing"（`skills/reproduce-and-fix-issues/SKILL.md`）に倣い、失敗するテストを先に書いて 2 回落とす。再現できなければ実装せず `verdict ask unclear` に戻す。

## 7. 失敗時と観測

| 事象 | 検出 | 対応 |
|---|---|---|
| worker が 600 秒無進捗で止まる（`orca-parallel-agent-pipeline.md:31`） | `orca worktree ps` で `working` のまま `updatedAt` が 2 時間動かない | `candidates` 内の sweep が `needs-decision` + コメント `停止: #N <経過時間>` に上げる。再開は agent-resume に任せない（別起動 ID 前提のため）。人が SendMessage で続きを指示 |
| テストが赤のまま | worker 自身が 2 回直しても赤なら、commit は push せず `needs-decision` に上げる | コメント `赤: #N <テスト名>` |
| 429 / API 障害 | 全 worker が同時に止まる（同 :31） | 上と同じ sweep。dispatcher 側は precheck が `gh` 失敗で exit 1 → `skipped_precheck` で run が飛ぶ |
| codex 枠が空かない | §5 | review を飛ばし PR 本文に明記 |
| setup 失敗（docker 起動など） | worker が `make up` の失敗を見る | 1 回だけ `make setup` を再実行、だめなら `needs-decision` に `setup 失敗: #N` |
| precheck の失敗 | `orca automations runs --id <id>` の `skipped_precheck` | ログで原因を見る |

観測:
- スクリプトのログ: `~/Library/Logs/issue-autopilot.log`（precheck の stdout が Orca のどこに残るか未確認なので、自前で追記する。recheck 必要）。
- state: `~/Library/Application Support/issue-autopilot/{verdicts.tsv,dispatched.tsv,board.tsv}`。`issue-autopilot.sh status` で表にする。
- run 履歴: `orca automations runs --id <id>`。
- ボード: worker のカードは `--display-name "app: #N <title 30 字>"`（CLAUDE.md:122 の形式）、PR を出したら `in-review`（`agents/skills/pr/SKILL.md:35`）。
- コスト: 既存の `agents/claude/usage-report.py` で transcript から集計。

## 8. 置き場所と登録

| もの | 場所 | 備考 |
|---|---|---|
| 判定・dispatch・sweep | `home/scripts/issue-autopilot.sh`（新規、サブコマンド `candidates` `verdict` `dispatch` `go` `skip` `status` `register`） | pr-dispatch と同じ bash + jq。`DRY_RUN=1` 対応 |
| automation 定義 | 同スクリプトの `register` が `orca automations list --json` を見て create / edit する（冪等） | 定義を Nix で宣言する価値は小さい。Orca 側の id を state に残す |
| triage の指示 | `agents/claude/skills/issue-autopilot/SKILL.md`（新規） | automation の `--prompt "/issue-autopilot"` |
| worker の指示 | `agents/claude/skills/issue-worker/SKILL.md`（新規） | `orca worktree create --prompt "/issue-worker <N>"`。人が手で使っても同じ動きになる |
| GC との接続 | `worktree-gc.sh` は変更不要 | PR が MERGED/CLOSED なら既存の条件で消える（`worktree-gc.sh:162-226`） |

skill は home-manager の symlink（`home/agent-skills.nix:26-27`）なので、追加後に rebuild が要る。automation の precheck は `~/www/personal/dotfiles/home/scripts/issue-autopilot.sh candidates` を絶対パスで呼ぶ。launchd の `run-from-main.nix:5` が避けている「レビュー前のスクリプトが無人で動く」問題はここにもあるが、dotfiles の checkout が main に居る運用なので受け入れる（推測: precheck の PATH と `gh` の認証は Orca の terminal 環境を継ぐ。§10 で確認）。

## 9. 導入手順

| 段階 | やること | 確認すること |
|---|---|---|
| 0 | skill 2 つとスクリプトを置き rebuild。`register --disabled`、`DISPATCH=0` | `orca automations show` で定義が意図どおり。`issue-autopilot.sh candidates` を手で回し `candidates.tsv` が妥当（既 worktree・既 PR・tracking が落ちている） |
| 1 | `orca automations run` を手で 2〜3 回 | `verdicts.tsv` の go/ask/skip と理由を人が全件読む。ask のコメントがカードに 1 行で出る。同じ issue を再判定していない。ルール判定の漏れ（auth/billing が go になっていない） |
| 2 | `DISPATCH=1`、`MAX_PER_RUN=1`、手動 run を 2〜3 回 | worker の transcript の `permissionMode`。setup タブが通る。失敗テスト → 修正 → 緑の順で証拠が PR 本文にある。PR が draft。branch が `issue-<N>-`。カード名・`in-review`。codex review が走った（枠の待ち方）。PR 後に pr-dispatch が拾う（ready にした時） |
| 3 | `orca automations edit --enabled`、上限は §5 の初期値、1 週間 | 1 日の件数、放置された needs-decision の数、worker の平均時間、429 の有無、`usage-report.py` のコスト。worktree-gc がマージ後に片付ける |
| 4 | 上限を上げる／ルールを緩める | ask の理由コード別の件数を見て、人が常に go にしているコードはルールから外す |

## 10. 未確定点と初回実験

1. permissionMode: worker 起動直後に transcript（`~/.claude/projects/<wt>/…jsonl`）の `permissionMode` を grep。auto でなければ `--surface terminal` でも試す。どちらも駄目なら `~/.claude/settings.json` の `defaultMode` で固定する。
2. precheck の実行環境: cwd・PATH・`gh auth status` を precheck で `log` に書いて確かめる。
3. 重なった run: `--trigger hourly` の run が前の run の終了を待つかは docs に無い。state のロックで二重 dispatch を防ぎ、実験で挙動を見る。
4. `--reuse-session` は使わない（extras と併用不可、`--help` 行 48）。毎回 fresh で state から読む。
5. worker 1 本の所要時間と 600 秒停止の頻度。トップレベル session なら起きない見込み（`orca-parallel-agent-pipeline.md:39`）だが 10 分超は未確認。
6. 判定の閾値（10 ファイル・300 行）は推測。段階 1 の verdict を見て直す。
7. triage モデルを Sonnet にして判定が甘くないか。甘ければ Opus に上げる（`--extra-agent-args="--model opus"`）。
8. draft のまま止めるか ready まで進めるか。段階 2 は draft 固定、段階 3 で ready まで進めて pr-dispatch と繋ぐ。

## 11. 変更するファイル

- 新規 `home/scripts/issue-autopilot.sh`
- 新規 `agents/claude/skills/issue-autopilot/SKILL.md`、`agents/claude/skills/issue-worker/SKILL.md`
- 変更なし: `home/scripts/worktree-gc.sh`、`home/scripts/pr-dispatch.sh`（挙動を前提にするだけ）
- 本書 `docs/issue-autopilot-design.md`

## 12. 後回し

- studio-api 以外のリポ。`--repo` と slug を引数にするだけで広がる。
- 判定結果を issue の Project/Status に反映する（外から見える。要るなら別途判断）。
- 5 時間上限の正確な読み取り（API が出たら）。
- 重なった run の制御が Orca 側で保証されたら state ロックを外す。
