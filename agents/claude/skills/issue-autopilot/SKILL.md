---
name: issue-autopilot
description: issue-autopilot の dispatcher。Orca automation から 2 時間おきに呼ばれ、自分の open issue を「一人で draft PR まで進めてよいか」で go / ask / skip に判定し、go を起動させる。人が手で /issue-autopilot と打っても同じ。実装はしない。
---

# /issue-autopilot

設計は dotfiles の `docs/issue-autopilot-design.md`。候補・重複・上限・状態遷移はスクリプトが決める。
ここでやるのは判定（§4.2）だけ。

```bash
IA=~/www/personal/dotfiles/home/scripts/issue-autopilot.sh
```

## 手順

1. `"$IA" candidates` を実行する。exit 1 なら何もせず終わる。
   - 出力の先頭 `# repo=<owner/repo> base=<branch> checkout=<path>` で対象を知る。
   - 行は `untriaged<TAB>N<TAB>updatedAt<TAB>title` と `pending<TAB>N...`。`pending` は判定済みなので読まない。
2. 判定のために対象リポのコードを最新にする。この worktree（dispatcher 用）で `git fetch origin` →
   `git switch --detach origin/<base>`。未コミットの変更があれば判定だけ行い、コードは推測せず `unclear` に倒す。
3. `untriaged` を上から（updatedAt の新しい順）**最大 8 件**、1 件ずつ読む。
   - `gh issue view <N> -R <repo> --comments`、本文が指すファイルを `rg` で探して読む。
   - 対象リポの `AGENTS.md` / `CLAUDE.md` に規則があれば従う。
4. 1 件ごとに `"$IA" verdict <N> <go|ask|skip> "<理由コード> <補足 20 字以内>"` を書く。
5. 最後に `"$IA" dispatch` を 1 回実行する（起動するかどうか・何件かはスクリプトが決める）。
6. 結果を 1〜3 行で返す（判定の件数と、起動した issue 番号）。

## 判定

**go** は次を全部満たすときだけ:

- 期待する振る舞いが書いてあり、テストで表せる。
- 対象リポで完結する。公開 API の形・DB スキーマ・デプロイ設定・secret を変えない。
- 触るファイル 10 以下、差分 300 行以下の見込み、新しい依存なし。
- Bug なら再現手順があるか、テストで再現できる見込みがある。

迷ったら **ask**。理由コード:

| コード | いつ |
|---|---|
| `spec` | 仕様・挙動を決める判断が要る |
| `scope` | 大きい、2 リポにまたがる、migration・依存追加が要る |
| `auth` `billing` `security` `pii` `prod` | その領域に触る |
| `unclear` | 期待する振る舞いが読み取れない、コードを確かめられない |
| `owner` | コメントで誰かが着手している |

**skip**: 重複している（`skip "dup #M"`）、既に直っている（`skip "fixed <sha>"`）。

## してはいけないこと

- コードを書く、commit・push する、ブランチを作る。
- `orca worktree set` や `orca agent launch` を自分で打つ（ボードと起動はスクリプトが行う）。
- issue・PR にコメントする、ラベルを変える。判定は GitHub に書かない。
- 9 件目以降を読む（次の run に回す）。
