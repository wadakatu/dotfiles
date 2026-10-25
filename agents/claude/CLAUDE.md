# グローバル指示

全プロジェクト共通。プロジェクト固有のことは各リポジトリの CLAUDE.md に書く。

## 応答

- 日本語で回答する。コード・コミットメッセージ・識別子は英語のまま。
- 不確かな API・オプション名・仕様は憶測で書かず、公式ドキュメントを引いてから答える。
  参照したら URL を示す。
- 回答は簡潔にまとめる。前置き・注意書きは短く保ち、本題に文字数を使う。
  説明を求められたら、詳細な解説を明示的に頼まれない限りは要点の要約に留める。
- 最初のツール呼び出し前に何をするかを一文で言い、途中は重要な発見や方針転換を報告する。
  終わったら結果から書き出す。
- ディスクに書くドキュメント（レポート・要約・設計メモ）は、必要な中身は網羅しつつ
  埋め草の節・重複する要約・定型文で膨らませない。

## この Mac の環境

- **nix-darwin + home-manager 管理**。`~/.zshrc` `~/.config/git/config`
  `~/.config/ghostty/config` などは `/nix/store` への読み取り専用シンボリックリンク。
  **直接編集しない**。実体は `~/www/personal/dotfiles` にあり、そこを直してから反映する。
- 反映コマンドは副作用が大きいので、自分で実行せずプロンプトに提示してユーザーに実行してもらう:
  `! cd ~/www/personal/dotfiles && sudo darwin-rebuild switch --flake .#mymac`
- ランタイムは **mise**（node / bun / pnpm / yarn / python）。PHP は **Herd**（8.2〜8.5）。
- 使えるツール: `gh` `rg` `jq` `yq` `glow` `age` `uv` `imagemagick` `gcloud`
- `mise exec` / `npx` / `docker exec` のようなランナー経由の実行は権限ルールをすり抜けるので、
  中身のコマンドを直接書く。

## Claude Code 自身の設定

`~/.claude/{settings.json,CLAUDE.md,statusline.py,commands,skills,hooks}` は
**`~/www/personal/dotfiles/agents/claude/` が正**。`~/.claude` 側は手動コピーされた複製。
Codex の `~/.codex/AGENTS.md` も同じく **`~/www/personal/dotfiles/agents/codex/AGENTS.md` が正**。

`~/.claude` や `~/.codex/AGENTS.md` を直接編集したら、同じ内容を dotfiles 側にも反映してコミットすること
（逆方向のコピーは `~/www/personal/dotfiles/README.md` の手順を参照）。

## 作業のしかた

- テストが落ちたら落ちたと報告する。通っていない状態を「完了」と言わない。

## 委任の線引き

人間がボトルネックにならないよう、次の線で動く。どちらか迷うものは止まって聞く。

**聞かずに進め、事後に報告する**

- 自分の作業ブランチへの push と PR 作成（検証が通ってから。マージは承認レビューで人が見る）。
- 自分の PR に付いたレビュー指摘への返信とリアクション。
  ただし人間の指摘を「対応しない」と断る返信だけは、文面を見せてから投稿する。
- 作業中に見つけた「別 issue で対応」の起票。重複検索と Issue Type の設定は必ず行う。
- issue のクローズ。解決を検証し、根拠コメントを付ける。
- 実装の二択で、動かせば答えが出るもの。試すだけでなく公式ドキュメントやベストプラクティスも
  出典付きで調べ、その時点で使える最も賢いモデルで判断する。
- PR が MERGED / CLOSED になった worktree の削除と docker の停止。未コミット変更なし・
  PR に入っていないコミットなし・中のエージェントが作業中でない、をすべて満たすとき。

**止まって聞く**

- 本番への反映（本番ブランチへの push・release、本番環境への apply・デプロイ）。
- 仕様・挙動・API の形・スコープが変わる判断。
- 他人の PR・issue へのコメント（レビューを含む）。
- Slack・メール・社外への発信。社内外とも、送る前に文面を見せる。
- 上記以外の破壊的・不可逆な操作（force push を除く履歴書き換え、データやクラウド資源の削除）。

止まって聞くとき、Orca の worktree にいれば
`orca worktree set --worktree current --workspace-status needs-decision --unread --comment "<何を判断してほしいか 1 行>" --json`
でボードの Needs decision 列にカードを移す。判断をもらったら `--workspace-status in-progress --read` に戻す。
（`needs-decision` は Needs decision 列の内部名。UI で列を作り直すと `status-<番号>` になるので、そのときは内部名を付け直す。）結果に `warnings` が出たら列が無いか内部名が変わっているので、未読マークと一言だけで知らせて報告する。
