# dotfiles

macOS の開発環境を nix-darwin、Home Manager、Nix flakes で宣言管理する。

Nix由来のパッケージと設定は `flake.lock` で固定する。Homebrew cask、アプリ自身の
自動更新、macOS、認証情報、ユーザーデータは固定対象外のため、完全なディスク複製ではなく
「必要な開発環境を短時間で再構築できる状態」を目標とする。

移行中の棚卸し状況は [Mac migration audit](./docs/migration-audit.md) を参照。

## 管理範囲

| 領域 | 管理方法 |
|---|---|
| zsh / Git / GitHub CLI / fzf / Starship | Home Manager `programs.*` |
| mise とグローバルランタイム | Home Manager `programs.mise` |
| Neovim と設定 | Home Manager + `home/config/nvim` |
| Ghostty と設定 | Homebrew cask + Home Manager |
| CLI パッケージ | nixpkgs `home.packages` |
| GUI アプリ | nix-darwin `homebrew.casks` |
| Dock / Finder / キーボード / スクリーンショット | nix-darwin `system.defaults` |
| シークレット、アプリデータ、ブラウザデータ | Keychain / 1Password / バックアップ |

## 構成

```text
.
├── flake.nix
├── flake.lock
├── home/
│   ├── default.nix
│   ├── git.nix
│   ├── ghostty.nix
│   ├── mise.nix
│   ├── neovim.nix
│   ├── packages.nix
│   ├── zsh.nix
│   └── config/
│       ├── ghostty/config
│       ├── nvim/
│       └── starship.toml
├── modules/homebrew.nix
├── system/defaults.nix
└── docs/migration-audit.md
```

ユーザー名は `flake.nix` の `username` 1か所を正とし、現在は `wadakatu` を指定している。
新しい Mac のアカウント short name と一致させること。

## 前提

- Apple Silicon Mac
- 管理者権限
- 作業前のTime Machineまたは同等のバックアップ
- [Determinate Nix for macOS](https://docs.determinate.systems/getting-started/individuals/)
- [Homebrew](https://brew.sh/)

nix-darwinはHomebrew本体をインストールしないため、Homebrewは先に用意する。

## 新しい Mac の初回セットアップ

```bash
git clone https://github.com/wadakatu/dotfiles.git ~/www/dotfiles
cd ~/www/dotfiles

# 評価とビルド。ユーザー環境にはまだ適用しない
nix flake check --show-trace
nix build .#darwinConfigurations.mymac.system --no-link --show-trace

# 初回だけ nix run で darwin-rebuild を起動する
sudo nix run nix-darwin/master#darwin-rebuild -- \
  switch --flake .#mymac
```

初回適用後はターミナルを開き直す。

## 現 Mac で初回適用する前の注意

- 現在の `~/.zshrc` はHome Managerと衝突するため、`before-hm` suffixで退避される。
- `~/.gitconfig` とHome Managerが生成する `~/.config/git/config` はGitから両方読まれる。
  移植内容を確認後、旧 `~/.gitconfig` は手動で退避する。
- `GITHUB_TOKEN=$(gh auth token)` のようにトークンを常時環境変数へ展開しない。
  新しい Mac では `gh auth login` でKeychainへ保存する。
- Homebrewのcleanupは棚卸し完了まで `none` とし、未宣言パッケージを削除しない。

## 日常運用

```bash
# 副作用なしのビルド確認
darwin-rebuild build --flake .#mymac

# 確認後に適用
sudo darwin-rebuild switch --flake .#mymac

# input更新。lockfile差分とビルド結果を確認してから適用する
nix flake update
nix flake check --show-trace
darwin-rebuild build --flake .#mymac
```

新しいNixファイルはGitの追跡対象でないとflakeから見えない。追加後はビルド前に
`git add <file>` する。

## シークレットと移行対象外データ

次のデータはコミットしない。

- API token、PAT、秘密鍵、`.env*`
- GitHub CLIやGoogle Cloud SDKの認証情報
- SSH / GPG秘密鍵
- Herd、Docker、ブラウザ、各GUIアプリのユーザーデータ

これらはKeychain、1Password、Time Machine、各サービスへの再ログインで移行する。
