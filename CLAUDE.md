# CLAUDE.md

> **Historical document:** 以下は2026年5月に完了したNix移行の設計記録。
> 現在の構成・セットアップ手順は `README.md`、新Mac移行の判断状況は
> `docs/migration-audit.md` を正とする。
> 2026年7月の棚卸しでiTerm2は不要と判断し、プロファイルも削除した。

このリポジトリで実施したNix移行の背景と判断記録。

## このプロジェクトの目的

macOS 用 dotfiles を **nix-darwin + home-manager + Nix flakes** に段階的に移行する。
新しい Mac で `nix run nix-darwin -- switch --flake .#mymac` 一発で同じ環境（CLI ツール、GUI アプリ、シェル設定、macOS システム設定）が再現される状態を目指す。

**移行のモチベーション**
- バージョンを `flake.lock` で完全固定し、3年後でも同じ環境を立ち上げられること
- 環境構築を宣言的に記述し、ロールバック可能にすること
- 並行して Nix / 関数型 DSL / flakes を学習すること（**学習が目的の一部**）

## 学習優先のコラボレーションスタイル

ユーザーは Nix 初学者であり、**手を動かして学ぶことが目的の一部**。Claude は以下を守ること：

- **「動くコードを丸投げ」ではなく「なぜそう書くか」を簡潔に説明する**。新しい概念（flake、module、overlay、derivation、`mkIf` など）が初登場するときは1–3行の補足を入れる
- **大きな変更を一気に投入しない**。Phase 単位（後述）で区切り、各 Phase の終わりに `darwin-rebuild switch` が通ることを確認してから次へ進む
- **既存ファイルをいきなり消さない**。`init.sh` / `symlink.sh` / `brew.sh` / `Brewfile` は Phase 5 で deprecate するまで残す
- **コマンドを実行する前にユーザーに見せる**。`darwin-rebuild switch` のような副作用のあるコマンドは、ユーザーが自分で実行できるようプロンプトに `! <command>` 形式で提示する
- **ユーザーから質問されたら、答える前に該当する公式ドキュメント or ソースを最低1つ提示する**
- **憶測で実装を進めない**。Nix の API、オプション名、モジュール構成、慣習などで少しでも不確かな点があれば、必ず以下のいずれかを参照してから手を動かす：
  - 公式マニュアル（[nix-darwin](https://nix-darwin.github.io/nix-darwin/manual/) / [home-manager](https://nix-community.github.io/home-manager/) / [Nixpkgs](https://nixos.org/manual/nixpkgs/stable/) / [Nix](https://nix.dev/manual/nix/)）
  - `nix-darwin` / `home-manager` の options 検索（`darwin-rebuild manpage` や [search.nixos.org](https://search.nixos.org/)）
  - 直近のコミュニティのベストプラクティス（[nix.dev](https://nix.dev/) や Discourse の最近のスレッド）
  - 「たぶんこうだろう」で flake.nix を書き始めない。誤ったオプション名や型は静的にも実行時にも detect されにくく、後の Phase で原因不明のエラーを引き起こすため

## 現状（移行前）

```
.
├── Brewfile        # CLI + cask 一覧
├── brew.sh         # brew bundle 実行スクリプト
├── init.sh         # Rosetta → symlink → brew の順で実行
├── symlink.sh      # zsh/git/vim を ~/.config 配下へシンボリックリンク
├── git/            # .gitconfig, .gitignore_global
├── iterm/          # iTerm2 プロファイル (wadakatu.json)
├── vim/            # .vimrc
└── zsh/            # .zshenv, .zshrc, aliases.zsh, paths.zsh, plugins.zsh, prompts.zsh, .fzf.zsh
```

セットアップ手順: `git clone` → `sh init.sh`。

## 目標構成（移行後）

```
.
├── flake.nix              # エントリポイント、inputs (nixpkgs, nix-darwin, home-manager) を定義
├── flake.lock             # バージョン固定
├── hosts/
│   └── mymac/             # ホスト別 nix-darwin 設定
│       └── default.nix
├── home/
│   ├── default.nix        # home-manager のエントリ
│   ├── zsh.nix            # programs.zsh.* に移行
│   ├── git.nix            # programs.git.* に移行
│   ├── vim.nix            # programs.vim.* に移行
│   └── packages.nix       # CLI ツール (環境変数 PATH に出るもの)
├── modules/
│   └── homebrew.nix       # nix-darwin の homebrew.casks (GUI アプリは brew のまま)
├── system/
│   └── defaults.nix       # macOS の defaults write 系を宣言化
└── iterm/wadakatu.json    # iTerm2 プロファイルは移行対象外（後述）
```

## 移行方針（Phase 単位）

各 Phase が独立して動作する状態を保ち、途中で頓挫しても現状に戻せるようにする。

### Phase 1: Nix 本体と最小 flake のセットアップ
- Determinate Nix Installer で Nix をインストール
- flake.nix の雛形を置き、`nix flake check` が通る状態にする
- この時点では既存の Brewfile / symlink.sh はそのまま動く

### Phase 2: home-manager で zsh / git / vim を宣言化
- `programs.zsh`, `programs.git`, `programs.vim` モジュールに段階的に書き換える
- ファイルの中身は `home.file` で参照する手もあるが、学習目的なので Nix のモジュールに置き換える方を優先
- 各設定を移行するたびに新シェルを立ち上げて挙動を確認

### Phase 3: Brewfile を nix-darwin に統合
- CLI ツール (`gcc`, `webp`, zsh プラグイン群) は **nixpkgs** に移す
- GUI cask (`phpstorm`, `chrome`, `slack` など自動更新するもの) は **`homebrew.casks`** として nix-darwin 経由で brew に残す
  - **理由**: Nix は GUI アプリの自動更新と相性が悪く、Spotlight 連携も弱いため
- `Brewfile` をリポジトリから消すのは Phase 5 で

### Phase 4: macOS システム設定の宣言化
- `system.defaults.dock`, `system.defaults.finder`, `system.defaults.NSGlobalDomain` など
- nix-darwin がカバーしていない設定は `system.activationScripts` で `defaults write` を呼ぶ

### Phase 5: レガシースクリプトの撤去と README 刷新
- `init.sh` / `symlink.sh` / `brew.sh` / `Brewfile` を削除（git history には残る）
- README に新しいセットアップ手順を書く

## 技術的な決定事項

- **flakes は必須**。`nix.settings.experimental-features = [ "nix-command" "flakes" ];`
- **GUI アプリは Homebrew cask のまま**。nix-darwin の `homebrew.casks` 経由で宣言する
- **iTerm2 プロファイル (`wadakatu.json`)** は引き続き手動 import。Nix での自動インポートは複雑度に見合わないため対象外
- **シークレット / 個人情報**（メールアドレス、SSH 鍵など）はリポジトリにコミットしない。`.gitconfig` の `user.email` などは `home.file` の代わりに別途管理する設計を検討
- **言語ランタイム**はPHP / ComposerをHerd、それ以外のグローバルランタイムをmiseで管理する。PythonはCodex・Claudeの汎用処理向けにmiseの`latest`（プレリリースを除く最新安定版）を使い、プロジェクト固有の設定を優先する。特定プロジェクトでは`direnv + nix develop` / `devenv`との共存も可能
- **Herd 注入の `HERD_PHP_XX_INI_SCAN_DIR`** は `home/zsh.nix` の `initContent` にハードコード。PHP バージョン追加時は Nix ファイルを更新する運用
- **Nix インストーラ**: [Determinate Nix Installer](https://github.com/DeterminateSystems/nix-installer) を採用。flakes デフォルト有効、クリーンなアンインストール可能
- **flake input URL**: Determinate 連携ガイドに合わせて flakehub.com URL を採用（SemVer ピン留め対応）
- **darwinConfiguration の名前**: ホスト名ではなく `mymac` という論理名を使う。新しい Mac でも `.#mymac` で同じ設定を呼べる
- **Determinate モジュール採用**: `determinate.darwinModules.default` + `determinateNix.enable = true` を flake に組み込み、nix-darwin の Nix 管理（`nix.settings.*` 等）は無効化。これらのオプションは書いても無視されるため記述しない

## ハマりポイントの参考リンク

- [nix-darwin manual](https://nix-darwin.github.io/nix-darwin/manual/)
- [home-manager manual](https://nix-community.github.io/home-manager/)
- [Davis Haupt: Managing dotfiles on macOS with Nix](https://davi.sh/blog/2024/02/nix-home-manager/)
- [Nix on MacOS - The Good, the Bad and the Ugly](https://drakerossman.com/blog/nix-on-macos-the-good-the-bad-and-the-ugly)

## ハマりポイント (運用時メモ)

- **`darwin-rebuild switch` 後にコマンドが見つからない**: `/etc/zshenv` のガードフラグ `__NIX_DARWIN_SET_ENVIRONMENT_DONE` のせい。`exec zsh` でも PATH 再構築されない。ターミナル丸ごと開き直すか、ガードフラグを unset してから `exec zsh`
- **nix-darwin が `Unexpected files in /etc` で失敗**: 該当ファイルを `.before-nix-darwin` リネームで通る (Issue #1298)
- **home-manager の `backupFileExtension` が symlink には効かない**: 既存 symlink は手で削除する必要あり (`check-link-targets.sh` 39行目の `! -L` 条件)
- **flake.nix を git add してないと Nix から見えない**: 「ファイルが存在しない」エラーで分かりにくい。新規 .nix ファイルは必ず `git add`

## Claude 向けの作業時チェックリスト

- [ ] 編集する前に該当 Phase の Task を `in_progress` に更新
- [ ] flake.nix を編集したら `nix flake check` の実行をユーザーに提案
- [ ] nix-darwin 設定を変えたら `darwin-rebuild build --flake .#mymac` で dry-run を先に提案
- [ ] Phase を完了したら、その Phase で学んだ Nix 概念を一言で要約してから次へ
