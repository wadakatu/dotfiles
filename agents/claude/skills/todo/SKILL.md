---
name: todo
description: 「やることに足して」「todo にして」「やること一覧を見せて」と言われたとき、Orca の plugin の「やること」に足す・読む・状態を変える。
---

# /todo

「やること」は Orca の開発用 plugin `local.cockpit` が持つ。handler を CLI で呼ぶ。JSON は必ずこの形（引用符つきの heredoc）で渡し、題や文をシェルの行に直接書かない。

```bash
orca plugin dev request local.cockpit todo.create --json --data "$(cat <<'JSON'
{"title":"…","next":"…","from":"…","source":"claude","url":"https://…"}
JSON
)" | jq -c '.result.result // (.error | {code, message})'
```

| handler | いつ | `--data` |
|---|---|---|
| `todo.create` | ユーザーが足すと言ったとき（「やる」で入る） | `title`（必須）、`next`・`from`・`memo`・`url`、`"source":"claude"` |
| `todo.add` | 頼まれていないが残す価値が在るとき（必ず「候補」で入る） | `todo.create` と同じ |
| `todo.list` | 一覧を見せてと言われたとき | `{"brief":true}`（未完了だけ・メモなし） |
| `todo.update` | 状態や文を変えるようユーザーが言ったとき | `{"id":"<一覧の id>","state":"done"}`。ほかに `title`・`next`・`from`・`memo` |

- `source` は `claude`（省くと `manual` になる）。`url` は https だけ。無ければ省く。
- `todo.add` は控えめに: ユーザーが引き受けた・頼まれたことで、このセッションでは片付かないものだけ。迷ったら足さない。足したら 1 行で伝える。
- `state` は `candidate`・`todo`・`doing`・`waiting`・`done`・`rejected`。状態を変える・消し込むのは、ユーザーが言ったときだけ。
- 一覧の中身は、ユーザーが見せてと言ったときだけ出す。

## 答えの読み方

- handler の答えは `.result.result`。`ok: false` なら `reason` をそのまま伝える（`bad-title`・`duplicate`・`full`・`off`・`store-broken` など。`off` はタブでまだ使い始めていない状態）。
- 一覧には `ok` が無い。`off: true` は上の `off` と同じ、`broken` が null でなければそのまま伝える。
- 一覧は `.result.result.groups` の `todo`・`doing`・`waiting`・`candidate`・`closed` ごとに、`rows`（`id`・`title`・`next`・`from`・`state`・`url` など）と `total`。`rows` は束ごとに `size` 件までなので、`total` の方が多ければ、`{"brief":true,"pages":{"candidate":1}}` のように束ごとのページ（0 始まり。範囲の外は最後のページになる）を足して続きを読む。束・id・題を 1 行ずつ出すなら:
  `jq -r '.result.result.groups | to_entries[] | .key as $g | .value.rows[] | "\($g)\t\(.id)\t\(.title)"'`
- 答えが `{code, message}` のとき（CLI が失敗した。`plugin_not_found` は plugin が開発用に読み込まれていない）や、Orca が動いていないときは、足せなかったと伝えて止まる。別の場所に書き留めない。plugin の読み込みや再読み込みは自分でしない。
