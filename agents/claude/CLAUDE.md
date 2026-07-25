# グローバル指示

全プロジェクト共通。プロジェクト固有のことは各リポジトリの CLAUDE.md に書く。

## 応答

- 日本語で回答する。コード・コミットメッセージ・識別子は英語のまま。
- 不確かな API・オプション名・仕様は憶測で書かず、公式ドキュメントを引いてから答える。
  参照したら URL を示す。

## この Mac の環境

- **nix-darwin + home-manager 管理**。`~/.zshrc` `~/.config/git/config`
  `~/.config/ghostty/config` などは `/nix/store` への読み取り専用シンボリックリンク。
  **直接編集しない**。実体は `~/www/dotfiles` にあり、そこを直してから反映する。
- 反映コマンドは副作用が大きいので、自分で実行せずプロンプトに提示してユーザーに実行してもらう:
  `! cd ~/www/dotfiles && sudo darwin-rebuild switch --flake .#mymac`
- ランタイムは **mise**（node / bun / pnpm / yarn / python）。PHP は **Herd**（8.2〜8.5）。
- 使えるツール: `gh` `rg` `jq` `yq` `glow` `age` `uv` `imagemagick` `gcloud`
- `mise exec` / `npx` / `docker exec` のようなランナー経由の実行は権限ルールをすり抜けるので、
  中身のコマンドを直接書く。

## Claude Code 自身の設定

`~/.claude/{settings.json,CLAUDE.md,statusline.py,commands,skills,hooks}` は
**`~/www/dotfiles/agents/claude/` が正**。`~/.claude` 側は手動コピーされた複製。

`~/.claude` を直接編集したら、同じ内容を dotfiles 側にも反映してコミットすること
（逆方向のコピーは `~/www/dotfiles/README.md` の手順を参照）。

## 作業のしかた

- 破壊的・不可逆な操作（force push を除く履歴書き換え、リソース削除、外部への送信）は
  実行前に確認する。
- テストが落ちたら落ちたと報告する。通っていない状態を「完了」と言わない。
