# 放置エージェントセッションの検出と停止（agent-gc）設計書

- v1（2026-11-02）: 自分で TERM → KILL し、子孫と agent-resume の印を片付ける案。
- v2（2026-11-02）: Codex の設計レビューで、KILL の経路に穴が多いと分かった（同じプロセスのまま別のセッションに切り替わる、子孫の範囲、印の競合、終了の確認）。
  止め方を「Orca の端末に `/exit` を送り、エージェント自身に終わってもらう」に変え、ユーザーの承認を得た。

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
launchd（StartInterval 600）→ agent-gc.sh scan
  1. memory pressure を読む
  2. Claude と Codex のプロセスを集め、1 本ずつ材料を JSON 1 行にする（3.1）
  3. judge（純粋な jq）で、候補か、keep とその理由かを決める（3.2）
  4. まだ知らせていない候補があれば通知する（4.1）
  5. ログに 1 行書く

ユーザー: agent-gc list           … 候補と、残した理由を一覧にし、listed.tsv に書く
          agent-gc stop <pid>...  … 判定し直し、入力欄が空なら /exit を送り、終わったかを確かめる
          agent-gc stop --listed  … listed.tsv の全件を、同じ手順で止める
```

1 つのスクリプト `home/scripts/agent-gc.sh` にまとめる。言語は既存のジョブと同じ bash と jq。launchd は `/bin/bash`（3.2）で起動するので、連想配列は使わない。

## 3. 判定

### 3.1 材料

**共通**

- `ps eww -o command= -p <pid>` から、`ORCA_PANE_KEY`、`ORCA_TERMINAL_HANDLE`、`ORCA_WORKTREE_ID` を取り出す。
  - 引数の中にも同じ文字列が出ることがある（codex の `-c shell_environment_policy.set.ORCA_...`）。そのため、前が空白の `NAME=` だけを拾い、最後に出たものを使う。環境変数は引数の後ろに並ぶ。
- `TZ=UTC ps -o lstart= -p <pid>` を、プロセスの開始時刻とする。止める直前に、この値で同じプロセスかを確かめる。
- 鍵は `<pid>:<開始時刻>:<最後の状態変化の時刻>`。通知の重複防止と、list で見せたものと同じかの照合に使う（4 節）。

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
> 代わりに、止める前にユーザーが list を見る。Claude には終了時の確認もある。必要が出たら「Claude のバックグラウンドタスクの有無」を材料に足す。

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
| 10 | パスが `EXCLUDE_RE` に合う | `excluded` |

judge は macOS のコマンドを呼ばない。このため Linux の CI でもテストできる。

Orca 上で working が古いまま残っているもの（実測で 2 本）は、表の 6 で keep になる。`agent-gc list` に `orca working` と出るので、ユーザーは目で拾える。

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

1. 材料を取り直して judge に通す。候補でなければ `skip <pid>: <理由>` とする。`--listed` のときは、鍵が listed.tsv と違えば `skip <pid>: changed since list` とする。
2. `ORCA_TERMINAL_HANDLE` が `orca terminal list` にあり、その `agentIdentity` がこのエージェント（claude / codex）であることを確かめる。そうでなければ skip する。
3. `orca terminal read --screen` の末尾から、入力欄が空であることを確かめる。書きかけの文字があるところに `/exit` を送ると、それが続けて送信されてしまうため。
   - `--screen` を付けないと、描画された画面ではなく出力の履歴が返る。そうすると、後から差分で描かれた書きかけを見落とす。応答の `source` が `screen` でなければ、止めない。
   - `draft`（Orca の入力欄に書きかけの文字）があるときも、止めない。
   - Claude：最後の `❯` の行が `❯` だけで、その次の行が入力欄の下の罫線である。複数行の書きかけは、2 行目以降に出るため。
   - Codex：最後の `› ` で始まる行が、`› Ask Codex to do anything` である。
     - 実測では、空の入力欄にこの placeholder が出ていた。
     - 書きかけの文字と placeholder は文字だけでは見分けられないので、この文言のときだけを空とみなす。
   - 当たらなければ `skip <pid>: input not empty`。
4. `DRY_RUN=1` なら、ここで `would stop` を出して次へ進む。
5. `orca terminal send --terminal <handle> --text /exit --enter` を送る。
6. 最大 20 秒、プロセスが消えるのを待つ。開始時刻が変わった場合も、消えたとみなす。
   - 消えたら：`stopped` をログに書く。
   - 消えなければ：`failed: still running` をログに書くだけで、KILL はしない。終了の確認画面などで止まっている可能性がある。ユーザーが端末を見て判断する。

ログの例：

```
2026-11-02 22:40:01 stopped claude pid=15450 idle=80h wt=/Users/.../gardening
2026-11-02 22:40:22 failed claude pid=31218: still running after /exit
2026-11-02 22:40:22 skip codex pid=68047: input not empty
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

- 自動では止めない。stop は止める直前に必ず判定し直し、鍵・端末・入力欄を確かめる。
- 材料が欠けたら、keep に倒す。
- KILL しない。`/exit` で終わらなければ、失敗としてログに残すだけにする。
- 形式の変化を検知する：claude のプロセスがあるのに、読めた記録が 0 本なら、`WARN` をログに書き、その日 1 回だけ通知する。
- 除外：`EXCLUDE_RE`（パスの正規表現）。既定は空。
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

ログは `~/Library/Logs/agent-gc.log`。scan は毎回 1 行書く。stop は 1 件ごとに 1 行書き、端末にも出す。

```
2026-11-02 22:30:00 scan pressure=2 sessions=36 candidates=15 new=3 unreadable=1
```

## 9. テスト

`tests/agent-gc.sh` に置く。偽のコマンドは使わず、純粋な部分だけを試す。CI（`nix.yml` の check ジョブ）で回す。

- `agent-gc.sh judge` に JSON の行を流し、表の 1〜10 の各理由と候補を照合する。
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

- 子孫の CPU やバックグラウンドタスクによる判定（3.1 の ponytail）。
- Orca の外のセッション。
- 候補が残り続けるときの再通知。
- Orca のカードへの印。
