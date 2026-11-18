# 放置エージェントセッションの検出と停止（agent-gc）設計書

- v1（2026-11-02）: 自分で TERM → KILL し、子孫と agent-resume の印を片付ける案。
- v2（2026-11-02）: Codex の設計レビューで、KILL の経路に穴が多いと分かった（同じプロセスのまま別のセッションに切り替わる、子孫の範囲、印の競合、終了の確認）。
  止め方を「Orca の端末に `/exit` を送り、エージェント自身に終わってもらう」に変え、ユーザーの承認を得た。
- v3（#187）: 自動で止める前の柵。巡回を origin/main の写しに替え、子孫のシェルと予約を作ったセッションを残し、送る直前に記録と入力欄を確かめ直し、台帳に戻らないものを書く。

材料の出典：

- 手元の実測（2026-11-02）。`~/.claude/sessions/*.json`（2.1.316）、`~/.codex/sessions/`（codex 0.166.0）、`orca worktree ps --json`・`orca terminal list/read --json`（Orca 1.4.244）、`ps`・`lsof`・`sysctl`。
- Codex の `/exit`：[slash_command.rs（rust-v0.166.0）](https://github.com/openai/codex/blob/rust-v0.166.0/codex-rs/tui/src/slash_command.rs)。`Quit | Exit => "exit Codex"`。
- 既存のスクリプト。`home/scripts/agent-resume.sh`、`memory-maintenance.sh`、`agents/claude/hooks/session-marker.sh`。

## 1. 意図と決まっていること

メモリが逼迫する主な原因は、作業が終わったのに閉じていないセッションである（36 本・約 21GB のうち、24h 以上 idle が 12 本・6.6GB）。これを 10 分ごとに見つけて通知し、ユーザーが確かめたものだけを止める。

- 判定と停止はルールで動くスクリプトが行う。AI は使わない。
- 自動で行うのは、見つけることと知らせることまで。止めるのは、ユーザーが `agent-gc stop` を打ったときだけ。
- 止めるときは、Orca の端末に `/exit` を送る。KILL はしない。エージェントが普段どおりに終わるので、次の 3 つはエージェント自身が行う。
  - MCP などの子プロセスの片付け。
  - 会話記録の保存。
  - 再開の案内の表示（`claude --resume <id>`、`codex resume <id>`）。
- agent-resume の印も、普段の終了と同じ経路で消える（6 節）。

非ゴール：

- 自動で止めること。
- Orca の外のセッション（端末が分からないので `/exit` を送れない）。herdr。
- 孤児プロセスの掃除。実測では 0 本だった。

## 2. 全体像

```
launchd（StartInterval 600）→ agent-gc-launcher scan --auto（origin/main の写しの agent-gc.sh）
  1. memory pressure を読む
  2. Claude と Codex のプロセスを集め、1 本ずつ材料を JSON 1 行にする（3.1）
  3. judge（純粋な jq）で、候補か、keep とその理由かを決める（3.2）
  4. sched で、候補の Claude のうち予約を作ったものを keep にする（3.3）
  5. まだ知らせていない候補があれば通知する（4.1）
  6. ログに 1 行書く

ユーザー: agent-gc list           … 候補と、残した理由を一覧にし、listed.tsv に書く
          agent-gc stop <pid>...  … 判定し直し、入力欄が空なら /exit を送り、終わったかを確かめる
          agent-gc stop --listed  … listed.tsv の全件を、同じ手順で止める
```

1 つのスクリプト `home/scripts/agent-gc.sh` にまとめる。言語は既存のジョブと同じ bash と jq。launchd は `/bin/bash`（3.2）で起動するので、連想配列は使わない。

巡回は、worktree-gc・pr-dispatch と同じく `home/run-from-main.nix` の起動スクリプトで origin/main の写しを動かす（checkout がレビュー前のブランチに居ても、その版は無人で動かない）。起動スクリプトは引数をそのまま渡す。`--auto` は LaunchAgent からの巡回の印で、今の `scan` は読まない（`scan` と同じに動く）。手で打つ `agent-gc`（`~/.local/bin/agent-gc`）は checkout のまま。

## 3. 判定

### 3.1 材料

**共通**

- `ps eww -o command= -p <pid>` から、`ORCA_PANE_KEY`、`ORCA_TERMINAL_HANDLE`、`ORCA_WORKTREE_ID` を取り出す。
  - 引数の中にも同じ文字列が出ることがある（codex の `-c shell_environment_policy.set.ORCA_...`）。そのため、前が空白の `NAME=` だけを拾い、最後に出たものを使う。環境変数は引数の後ろに並ぶ。
- `TZ=UTC ps -o lstart= -p <pid>` を、プロセスの開始時刻とする。止める直前に、この値で同じプロセスかを確かめる。
- 鍵は `<pid>:<開始時刻>:<最後の状態変化の時刻>`。通知の重複防止と、list で見せたものと同じかの照合に使う（4 節）。
- `ps -axo pid=,ppid=,comm=` を 1 回の collect につき 1 回だけ取り、セッションの pid から子孫を辿る（`bg_shell`）。コマンド名は空白を含みうるので 3 列目から行末までを取り、先頭の `-`（ログインシェル）とディレクトリを落とした名前が `zsh`・`bash`・`sh`・`fish`・`dash`・`ksh` のプロセスが居れば `true`、居なければ `false`。タブのシェルは祖先なので数えない。
  - 裏の Bash コマンドが走っている間は、claude の子孫にシェルが残る（Claude Code v2.1.326 の 1 例。そのときの記録の `status` は `shell` で、表の 2 でも残る）。公式が挙げる `status` は `busy`・`waiting`・`idle` だけなので、版が変わって `idle` と出ても残せるよう、プロセスの側でも見る。
  - ponytail: MCP のサーバをシェルのスクリプトで包んで起動している環境では、全部のセッションが `bg-shell` で残る（`agent-gc list` の「残すもの」に出る）。そうなったら、除く名前を設定で渡す。

**Claude**（`~/.claude/sessions/<pid>.json`。非公式の形式）

- `kind != "interactive"` のもの（`claude -p` など）は数えない。
- 次をすべて満たせば、読めたとする。満たさなければ `unreadable`。
  - `pid` が一致する。
  - `procStart` が `lstart` と一致する。
  - `status` が文字列である。
  - `statusUpdatedAt`（無ければ `updatedAt`）が数値である。
- プロセスがあるのに記録が無いものも、`unreadable` として一覧に出す。実測では、33 本のうち 1 本に記録が無かった。
- idle の時間は `now - statusUpdatedAt`。
  - `updatedAt` は使わない。名前の変更やセッションの切り替えでも更新されるため（Codex のレビューで、2.1.316 の実物から確かめた）。
  - `/clear` や `/branch` でセッションが切り替わっても、`statusUpdatedAt` が変わる。そのため鍵も変わり、list で見せたものとは別物として扱われる。

**Codex**

- `lsof -p <pid> -Fn` で、そのプロセスが開いている `~/.codex/sessions/**/rollout-*.jsonl` を集める。guardian などの副スレッドを含めて、複数あることがある。
- 開いている rollout がすべて次を満たせば、`status=idle` とする。idle の時間は、それらの timestamp の最大値から数える。
  - 最後の `event_msg` の `payload.type` が `task_complete` である。
  - ファイルが改行で終わっている。書きかけの行が無いということ。
- それ以外は次のとおりにする。
  - rollout が 1 つも無い、または読めない：`unreadable`。
  - 末尾が `task_complete` でないものがある：`status=busy`。
- 承認待ちは実測できていない。ただし、承認待ちは `task_complete` の前なので、`busy` に入る。
- 書き込みは、キューに積んでから遅れて行われる。そのため、ディスクの末尾が今の状態とずれることはありうる。
  - それでも、閾値（6h 以上）と比べれば、そのずれは無視できる。
  - 止める直前には、端末の入力欄が空であることも確かめる（5 節）。

**Orca**

`orca worktree ps --json` を 1 回だけ呼ぶ。次のどれかに当たれば、全セッションを `orca-unreachable` にする。

- 呼べない。
- `.result.truncated != false`。
- `.result.hostScope.omittedHostIds` が空でない。

`agents[].paneKey == ORCA_PANE_KEY` のエージェントを、このセッションとして扱う。worktree 単位ではなく、ペイン単位で見る。同じ worktree で別のエージェントが動いていても、このセッションとは関係ないため。

- `state`：このエージェントの状態。
- `sub_states`：`parentPaneKey == ORCA_PANE_KEY` のエージェントの状態の一覧。subagent に当たる。
  - 稼働中の subagent が、この形で出ることは確かめていない。
  - subagent の状態は `working / blocked / waiting / idle / unverifiable` で、`done` は使わない（Codex のレビューで Orca の実装から確かめた）。
  - そのため、`done` と `idle` 以外の状態が 1 つでもあれば keep にする。
- `workspace_status`：その worktree の `workspaceStatus`。文字列でなければ `orca-incomplete` にする。

> ponytail: 子孫の CPU で「裏で何か動いているか」を見る案（v1）は外した。理由は次のとおり。
> - 10 分平均では、短い負荷を取りこぼす。待ちの多い処理も拾えない。
> - idle の MCP と、動いている子を区別できない。
>
> 代わりに、子孫にシェルが居るか（上の `bg_shell`）と、予約を作ったか（3.3）を見る。モニターは見分けられない（動いている間の `status` も確かめていない）。

### 3.2 判定（`agent-gc.sh judge`）

stdin から 1 セッション 1 行の JSON を受け取り、`reason` を足して返す。`reason` が null なら候補とする。上から順に見て、最初に当たった理由で keep にする。値が欠けていれば、どの段でも keep の側に倒れる。

| 順 | keep にする条件 | 理由の表記 |
|---|---|---|
| 1 | 材料が読めない | `unreadable` |
| 2 | `status != "idle"` | `status=<値>` |
| 3 | `idle_sec < 閾値`。閾値は、`pressure >= 2` なら `IDLE_WARN_H`（6h）、そうでなければ `IDLE_H`（24h） | `idle <n>h` |
| 4 | Orca の応答が無い、または不完全 | `orca-unreachable` |
| 5 | このペインのエージェントが Orca に無い | `not-in-orca` |
| 6 | このペインのエージェントの `state != "done"` | `orca <state>` |
| 7 | subagent に、`done`・`idle` 以外がある | `orca-sub <state>` |
| 8 | `workspace_status` が文字列でない | `orca-incomplete` |
| 9 | `workspace_status == "needs-decision"` | `needs-decision` |
| 10 | `bg_shell` が `true`。`false` 以外（欠け）も残す | `bg-shell` / `bg-unknown` |
| 11 | パスが `EXCLUDE_RE` に合う | `excluded` |

judge は macOS のコマンドを呼ばない。このため Linux の CI でもテストできる。

Orca 上で working が古いまま残っているもの（実測で 2 本）は、表の 6 で keep になる。`agent-gc list` に `orca working` と出るので、ユーザーは目で拾える。

### 3.3 予約を作ったセッション（`sched`。Claude だけ）

未発火の予約タスク（`CronCreate`・`/loop`）は記録の `status` に出ない（1 例では、未発火の一度きりの予約が残る間も `idle` で、子孫にシェルも居なかった）。止めると、自分で間隔を決める `/loop` は `claude --resume` で戻らない（https://code.claude.com/docs/en/scheduled-tasks.md の Limitations）。未発火かを外から読む方法は確かめていないので、「会話記録に予約を作る呼び出しか、`/clear` で引き継いだ予約が 1 つでも在るセッションは残す」で粗く守る。

- `collect | judge` の後ろの 1 段で、`scan`・`list`・`stop` の 3 か所で通す。jq だけの judge には入れない（ファイルを読むため）。
- `reason` が null の Claude の行だけ、会話記録 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/<sessionId>.*`（退避された写しも含む）を読む。深さを問わず、`type` が `tool_use` で `name` が `CronCreate` か `ScheduleWakeup` の要素が 1 つでも在れば `scheduled`。実物では `.message.content[]` に在る。
- `/clear` の後の会話記録は新しい `sessionId` のファイルで、予約は同じプロセスに残って発火するのに `tool_use` は無い。残る痕跡は `/clear` と同じ時刻の `attachment` の 1 行（`.attachment.type` が `session_cron_carry`）だけなので、これも見る。深さを問わず、`type` が `session_cron_carry` の要素の `tasks` か `otherArmed` が空でない配列、または `wakeup` が null でなければ `scheduled`。中身が全部空なら予約なしとする。`tasks` が配列でない（無いを含む）、`otherArmed` が配列でも無いでもなければ、形が変わったとみなして `sched-unknown`（実物の carry にはどれも `tasks` が在った）。Claude Code 2.1.327 の実験で確かめた形で、公式ドキュメント（https://code.claude.com/docs/en/scheduled-tasks.md ）は `/clear` に触れていない。`tasks` と `otherArmed` の違いは確かめていない。
- 道具の名前は道具の一覧（`shape.tools[]`）・`attachment.addedNames[]`・本文にも、`session_cron_carry` は本文にも出うるので、文字列の一致では決めない。会話記録は数十 MB になるので、`grep -a -F` で行を絞ってから jq で確かめる（`-a` は NUL を含む記録でも行を出すため。GNU grep は行の代わりに `binary file matches` を出す）。
- 会話記録が見つからない・読めない、`sessionId` が無いか ID の形（英数字・`-`・`_`）でない、grep に当たった行が JSON として読めないとき、行が Claude の候補かを jq で読めなかったときは `sched-unknown`。どちらも keep で、`stop` は `skip <pid>: <理由>`、`list` の「残すもの」にも同じ理由で出る。`scan` のログの `sched_unknown=<n>` で、会話記録の無いセッションが黙って溜まらないようにする。
- ponytail: 済んだ予約・消した予約でも残る。未発火だけを見分けるなら、`CronDelete` と発火を突き合わせる。予約を作った後に `/resume` で会話を替えたセッションと、プロジェクトの永続の予約（`.claude/scheduled_tasks.json`）は見ない。

## 4. 通知と list

### 4.1 通知（scan）

- 候補の中に、`notified.tsv` に無い鍵があるときだけ通知する。1 回の scan で、通知は最大 1 件。
- 鍵は、そのプロセスが生きている間は消さない。消すのは、`<pid>:<開始時刻>` がもう存在しないとき（プロセスが終わったとき）だけ。
  - Orca に届かない、pressure が下がった、といった理由で一時的に候補から外れても、同じ放置を 2 回知らせることはない。
  - 再開して、また放置になれば、`statusUpdatedAt` が変わるので、改めて知らせる。
- 通知は osascript で出す（memory-maintenance と同じ）。
  - タイトル：`agent-gc`
  - 本文：`止める候補 12 本（新規 3）。agent-gc list で確かめて agent-gc stop --listed`
- memory pressure の値は、ログにだけ書く。

Orca のカードには印を付けない。comment はエージェントが状態を書く欄で、`--unread` は agent-resume が別の意味で使っているため。

### 4.2 CLI（`~/.local/bin/agent-gc` → リポのスクリプトへの out-of-store symlink）

```
agent-gc list              候補 → keep の順に一覧する（pid, agent, idle, worktree, 理由）
                           候補を listed.tsv（pid と鍵）に書く。listed.tsv を書くのは list だけ
agent-gc stop <pid>...     指定した pid を止める
agent-gc stop --listed     最後に list で見せた候補を止める。始めに listed.tsv を読み込み、その鍵と一致するものだけを止める
DRY_RUN=1 agent-gc stop …  判定し直して、止める対象を表示するだけ
```

`stop --listed` が止めるのは、list で見せて、そのあと何も変わっていないセッションだけになる。止める直前の鍵（pid・開始時刻・状態変化の時刻）が、listed.tsv と一致しなければ止めない。

- scan は listed.tsv を書かない。そのため、list の後に通知で新しく出た候補は含まれない。
- `/clear` でセッションが切り替わった、再開して使った、といったものも含まれない。

候補でない pid を無理に止める `--force` は作らない。そういうセッションは、Orca のタブを閉じれば止まる。

## 5. 止め方（stop の 1 件ごと）

その前に 1 回だけ（#157）：

- 共有ファイル `home/scripts/cleanup-ledger.sh` を、スクリプトの実体の隣から読む。`~/.local/bin/agent-gc` は nix の store を挟んだ symlink の連なりなので、`readlink` を 1 段ずつ辿って実体を求める。読めなければ 1 本も止めない（scan と list は今どおり）。
- 「触らない」リスト（`keep_load`）を読む。無い・読めない回（解釈できない行がある回を含む）は 1 本も `/exit` を送らず、ログに理由を書き、通知をその日 1 回だけ出す（印は「無い」が `keep-missing-warned`、「読めない行が在る」が `keep-unreadable-warned` で、同じ日に両方出せる。worktree-gc のものとは別。`DRY_RUN=1` では通知も印も出さない）。

1. 材料を取り直して judge と sched に通す。候補でなければ `skip <pid>: <理由>` とする。`--listed` のときは、鍵が listed.tsv と違えば `skip <pid>: changed since list` とする。cwd が空か絶対パスでなければ（記録に `cwd` が無い、Codex の `lsof` が失敗した）、リストに当たるか判定できないので `skip <pid>: cwd が分からない` とする。cwd が「触らない」リストの行そのものか行の下なら（`keep_match`。行が cwd の中を指す祖先の一致は使わない。セッションを止めても中身は消えないため）skip する。`EXCLUDE_RE` は judge の表の 11 に残し、どちらかに当たれば止めない。
2. `ORCA_TERMINAL_HANDLE` が `orca terminal list` にあり、その `agentIdentity` がこのエージェント（claude / codex）であることを確かめる。そうでなければ skip する。
3. 戻し方と規則を組む。セッション ID（`sessions/<pid>.json` の `sessionId`）も起動時の引数も終了で消えるので、送る前に控える。下の (a)・(b) の後に外部コマンド（`ps`・`jq`）を挟まないよう、確認より先に組む。
   - Claude：`cd <cwd> && claude <引数> --resume <ID>`。引数は、起動時の引数のうち `--plugin-dir`・`--model`・`--effort`（`--flag 値` と `--flag=値` の両方。値が空か `-` で始まるものは除く）だけを `printf %q` で付ける。位置引数の指示（`/some-command <URL>`）や `--prefill` は、再開のときに次のターンとして実行されるので付けない。
     - 引数を `--resume` の前に置くのは、この戻し方で再開したセッションを次に止めたとき、`--resume` の ID を位置引数と取り違えて引数を落とさないため。走査は `--resume`・`-r` とその値（`-` で始まらないトークン）を読み飛ばす。
     - `ps` は argv の境界を残さないので、`--plugin-dir` の値は続くトークンを足して実在するディレクトリになる最長のものにする（`~/Library/Application Support/...` のように空白を含む）。走査は位置引数の始まりで止める。
   - Codex：`cd <cwd> && codex resume`（一覧から選ぶ）。ID は rollout の 1 行目（`session_meta`）から引けそうだが、`codex resume <ID>` で再開まで通るかを確かめていないので残さない。
   - ID が無ければ、先頭に `: 一覧から選ぶ;` を付ける。`#` のコメントにしないのは、対話の zsh が既定で `interactive_comments` を無効にしていて、貼ると注記が引数として渡るため。
4. (a) 記録を読み直す。判定の後に始まったターンを拾うため。Claude は `sessions/<pid>.json` の `status` が `idle` で、`statusUpdatedAt`（無ければ `updatedAt`）が判定時（鍵の最後の欄）と同じこと。Codex は `codex_state` が idle で、時刻が判定時と同じこと。違えば `skip <pid>: changed before send`。
5. (b) `orca terminal read --screen` の末尾から、入力欄が空であることを確かめる。書きかけの文字があるところに `/exit` を送ると、それが続けて送信されてしまうため。
   - `--screen` を付けないと、描画された画面ではなく出力の履歴が返る。そうすると、後から差分で描かれた書きかけを見落とす。応答の `source` が `screen` でなければ、止めない。
   - `draft`（Orca の入力欄に書きかけの文字）があるときも、止めない。
   - Claude：最後の `❯` の行が `❯` だけで、その次の行が入力欄の下の罫線である。複数行の書きかけは、2 行目以降に出るため。
   - Codex：最後の `› ` で始まる行が、`› Ask Codex to do anything` である。
     - 実測では、空の入力欄にこの placeholder が出ていた。
     - 書きかけの文字と placeholder は文字だけでは見分けられないので、この文言のときだけを空とみなす。
   - 当たらなければ `skip <pid>: input not empty`。
6. `DRY_RUN=1` なら、ここで `would stop` を出して次へ進む。(b) の後は、外部コマンドを挟まずに 7 を送る。
7. `orca terminal send --terminal <handle> --text /exit --enter` を送る。
8. 最大 20 秒、プロセスが消えるのを待つ。開始時刻が変わった場合も、消えたとみなす。
   - 消えたら：`stopped` をログに書き、共有の台帳（`ledger_add`）に 1 行足す。種類 `session`、対象 `<agent> <cwd>`、規則 `idle <n>h >= <閾値>h`（pressure が WARN 以上なら ` (memory pressure WARN)`）、戻し方、戻らないもの。戻らないものは、Claude は `裏のコマンド・モニター・自分で間隔を決める /loop（在ったかは分からない）`（`claude --resume` は期限内の `CronCreate` の予約を戻すが、これらは戻さない。https://code.claude.com/docs/en/scheduled-tasks.md の Limitations）、Codex は空（確かめていない）。
   - 消えなければ：`failed: still running` をログに書き、KILL はしない。終了の確認画面などで止まっている可能性がある。ユーザーが端末を見て判断する。`/exit` は届いていて待ち時間の後で終わることもあるので、台帳にも規則に ` (/exit 送信済み・終了は未確認)` を付けて 1 行足す。

ログの例：

```
2026-11-02 22:40:01 stopped claude pid=15450 idle=80h wt=/Users/.../gardening
2026-11-02 22:40:22 failed claude pid=31218: still running after /exit
2026-11-02 22:40:22 skip codex pid=68047: input not empty
2026-11-02 22:40:23 skip claude pid=50112: bg-shell
2026-11-02 22:40:23 skip claude pid=50190: scheduled
```

Orca のタブは閉じない。シェルが残るので、表示された `claude --resume <id>` か `codex resume <id>` で、そこから再開できる。

## 6. 既存のジョブとの関係

- **agent-resume**：
  - 今の起動の印で、プロセスが無いものは「普通に終わったセッション」として 3 分以内に消される。`/exit` で終わったセッションも、この経路に乗る。agent-gc は印に触らない。
  - ponytail：止めてから 3 分以内に Mac を再起動すると、そのセッションが再開されてしまう。手で `/exit` したときと同じ挙動なので、そのままにする。
  - Needs decision の開き直しとは重ならない。needs-decision は表の 9 で keep になるため。
- **worktree-gc**：PR がマージされた worktree を消すので、その中のセッションも消える。agent-gc は「PR は進行中だが、セッションは放置」の分を担う。
- **memory-maintenance**：関係しない。書き方（ログ、`DRY_RUN`、`notify()`、PATH、`LC_ALL`）だけを合わせる。

## 7. 安全策

- 自動では止めない。stop は止める直前に必ず判定し直し、鍵・端末を確かめ、送る直前に記録と入力欄を続けて確かめ直す。
- 材料が欠けたら、keep に倒す。
- KILL しない。`/exit` で終わらなければ、失敗としてログに残すだけにする。
- 形式の変化を検知する：claude のプロセスがあるのに、読めた記録が 0 本なら、`WARN` をログに書き、その日 1 回だけ通知する。
- 除外：「触らない」リスト（`~/.config/cleanup-keep`、worktree-gc と共有）と `EXCLUDE_RE`（パスの正規表現。既定は空）。どちらかに当たれば止めない。リストが無い回の stop は 1 本も止めない。
- 多重実行のロックは置かない。
  - scan は launchd が重ねて起動しない。
  - list と stop は人が打つ。
  - 3 つが共有する状態は、`notified.tsv`（scan だけが書く）と `listed.tsv`（list だけが書く）だけ。

## 8. 状態とログ

状態は `~/Library/Application Support/agent-gc/` に置く。

| ファイル | 中身 |
|---|---|
| `notified.tsv` | 知らせた鍵 |
| `listed.tsv` | 最後に list で見せた候補（pid と鍵） |
| `format-warned` | 形式の警告を出した日付 |
| `keep-missing-warned` | 「触らない」リストが無い（読めない）と知らせた日付 |
| `keep-unreadable-warned` | 「触らない」リストに読めない行があると知らせた日付 |

置き場所の根は `STATE_ROOT`（cleanup-ledger.sh と同じ）。止めたものの台帳は共有の `cleanup-ledger/ledger.tsv` に書く。

ログは `~/Library/Logs/agent-gc.log`。scan は毎回 1 行書く。stop は 1 件ごとに 1 行書き、端末にも出す。

```
2026-11-02 22:30:00 scan pressure=2 sessions=36 candidates=15 new=3 unreadable=1 sched_unknown=0
```

## 9. テスト

`tests/agent-gc.sh` に置く。CI（`nix.yml` の check ジョブ）で回す。judge と prompt-empty は偽のコマンドを使わずに試す。stop（#157 の台帳と「触らない」リスト、#187 の子孫のシェル・予約・送る直前の確認）は `ps`・`lsof`・`sysctl`・`orca`・`osascript`・`sleep` を偽物にして試す。偽の `ps` は本物と同じく引数を空白で繋いだ 1 行で返す。

- `agent-gc.sh judge` に JSON の行を流し、表の 1〜11 の各理由と候補を照合する。
  - pressure による閾値の切り替え。
  - 値が欠けたときに keep になること。
  - Codex の候補。
- `agent-gc.sh prompt-empty <agent>` に端末の末尾を流し、空・書きかけ・placeholder の別の文言・shell に戻った画面を照合する。

ps・lsof・orca からの収集は macOS 専用で、形式も非公式なので、テストにしない。10 節の実機確認で代える。

## 10. 導入順と、実機で確かめること

1. 実装して、`bash tests/agent-gc.sh` と `nix flake check` を通す。新しい .nix は `git add` する。
2. 手元で `home/scripts/agent-gc.sh list` を打ち、今日の実測と見比べる。
   - 6h 閾値で、十数本が候補になる。
   - working が古いまま残る 2 本と、needs-decision のものは keep になる。
3. ユーザーが選んだ 1 本で、`DRY_RUN=1 … stop <pid>` を打ってから `… stop <pid>` を打ち、次を確かめる。
   - `/exit` で終わり、再開の案内が出るか。
   - MCP の子プロセスが残らないか。
   - `claude --resume <id>` で戻れるか。
4. Codex を 1 本、同じ手順で確かめる。
5. rebuild（ユーザーが手で打つ）で、launchd と `~/.local/bin/agent-gc` を入れる。

## 11. 変更するファイル

| ファイル | 変更 |
|---|---|
| `home/scripts/agent-gc.sh` | 新規。scan / list / stop / judge / prompt-empty |
| `home/agent-gc.nix` | 新規。`launchd.agents.agent-gc` と `home.file.".local/bin/agent-gc"` |
| `home/default.nix` | imports に足す |
| `tests/agent-gc.sh` | 新規 |
| `.github/workflows/nix.yml` | check ジョブに足す |
| `README.md` | 管理範囲の表、構成の木、手で打つコマンド |

## 12. 後回しにしたこと

- 子孫の CPU による判定と、モニターの検出（3.1 の ponytail）。未発火の予約だけを見分けること（3.3）。
- Orca の外のセッション。
- 候補が残り続けるときの再通知。
- Orca のカードへの印。
