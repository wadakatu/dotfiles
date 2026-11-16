---
paths:
  - "**/cleanup-ledger.sh"
  - "**/worktree-gc.sh"
  - "**/agent-gc.sh"
---

# 掃除ジョブが止めた・消したものについて聞かれたら

「◯◯を消してほしくなかった」「何が消えた？」と言われたら、次の順に進める。

- 台帳 `~/Library/Application Support/cleanup-ledger/ledger.tsv`（列は 時刻 / 種類 / 対象 / 規則 / 戻し方 / 戻らないもの）を直接読み、ジョブと規則を特定する。種類 `worktree`・`compose-down`・`worktree-remove-failed`・`compose-stop` は worktree-gc、`session` は agent-gc。
- 戻し方の列を示し、流す前に何が起きるかを伝える。先頭の `: …;` は注記。
  - `worktree`: `git worktree add …`。`worktree-remove-failed` は残ったフォルダを退けてから。`: HEAD を取れなかった…` は戻せない。
  - `compose-stop`: `docker start <ID…>`。
  - `session`: `claude <引数> --resume <ID>`。`: 一覧から選ぶ;` は再開の一覧から。規則に「終了は未確認」とあれば、まだ動いていないか先に確かめる。
  - `claude --resume`・`codex resume` が入る行（`worktree` の行にも付く）は、その部分を自分では実行せず、ユーザーに端末で打ってもらう。`git worktree add` までは自分で流してよい。
- 戻らないもの（ignore されたファイル、消えた volume、Orca のカード、孤児のコンテナ）は、戻らないと伝える。
- その対象だけ守るなら「触らない」リスト `~/.config/cleanup-keep` に足す。1 行 1 つ、`/` で始まるか `~`・`~/…` ならパスの接頭辞、それ以外は compose project の名前。コメントは行頭の `#` だけで、`$HOME` や引用符は使えず、読めない行が在るとその回は何も消さない。ファイルが無いのは「何も止めない・消さない」の印なので、自分の判断では作らず、作るかをユーザーに確かめる。
- 規則が誤っているなら dotfiles の issue にする。公開リポなので、対象の名前やパスは書かず規則だけを書く。

**Why:** 掃除ジョブが消したものが分からず、不満の伝え先も決まっていなかった。
