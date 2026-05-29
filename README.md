# dotfiles

macOS の開発環境を **[nix-darwin](https://github.com/nix-darwin/nix-darwin) + [home-manager](https://github.com/nix-community/home-manager) + [Nix flakes](https://nix.dev/concepts/flakes.html)** で宣言的に管理する dotfiles。

新しい Mac でもコマンド一発で、CLI ツール・GUI アプリ・シェル設定・macOS システム設定を同じ状態に再現できる。バージョンは `flake.lock` で固定されるため、時間が経っても同じ環境を立ち上げられる。

## 構成

```
.
├── flake.nix            # エントリポイント。inputs (nixpkgs / nix-darwin / home-manager / determinate) と
│                        #   darwinConfigurations."mymac" を定義
├── flake.lock           # 全 input のバージョン固定
├── home/                # home-manager (ユーザー領域 ~/)
│   ├── default.nix      #   エントリ。子モジュールを import
│   ├── zsh.nix          #   programs.zsh / fzf / starship
│   ├── git.nix          #   programs.git
│   ├── vim.nix          #   programs.vim
│   └── packages.nix     #   CLI ツール (home.packages)
├── modules/
│   └── homebrew.nix     # nix-darwin の homebrew.casks (GUI アプリは brew 管理のまま)
├── system/
│   └── defaults.nix     # macOS システム設定 (system.defaults.*)
└── iterm/wadakatu.json  # iTerm2 プロファイル (手動 import。Nix 管理外)
```

| 領域 | 管理方法 |
|---|---|
| シェル (zsh/fzf/starship)・git・vim | home-manager の `programs.*`（設定はインライン宣言） |
| CLI ツール (`gcc`, `libwebp` など) | nixpkgs → `home.packages` |
| GUI アプリ (`phpstorm`, `chrome`, `slack` など) | `homebrew.casks` 経由で Homebrew が管理（自動更新・Spotlight 連携のため） |
| macOS システム設定 (Dock/Finder/キーボード/スクショ) | `system.defaults.*` |

## 前提

- macOS (Apple Silicon。Intel の場合は `flake.nix` の `nixpkgs.hostPlatform` を `x86_64-darwin` に)
- [Determinate Nix Installer](https://github.com/DeterminateSystems/nix-installer) で Nix をインストール（flakes デフォルト有効）

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
  ```
- GUI アプリ用に [Homebrew](https://brew.sh/) をインストール（nix-darwin は cask を管理するが Homebrew 本体は別途必要）

## 新しい Mac でのセットアップ

```bash
git clone https://github.com/wadakatu/dotfiles.git
cd dotfiles

# 初回適用 (nix-darwin 未インストールの状態から)
nix run nix-darwin -- switch --flake .#mymac
```

`mymac` はホスト名に依存しない論理名。どの Mac でも `.#mymac` で同じ設定を呼べる。

> 初回 activation で既存の `~/.zshrc` 等と衝突した場合は `.before-nix-darwin` / `.before-hm` にバックアップされる。`Unexpected files in /etc` で止まる場合は該当ファイルを `.before-nix-darwin` にリネームして再実行する。

## 日常運用

```bash
# 設定を変更したあと適用
sudo darwin-rebuild switch --flake .#mymac

# 適用前に dry-run でビルドだけ確認
darwin-rebuild build --flake .#mymac

# 依存を最新化 (flake.lock 更新) してから適用
nix flake update
sudo darwin-rebuild switch --flake .#mymac
```

> 新規 `.nix` ファイルは `git add` しないと flake から見えない（「ファイルが存在しない」エラーになる）点に注意。

## メモ

- **言語ランタイム** (PHP/Node/Python 等) は当面 Herd / volta などに任せる。Herd 注入の `HERD_PHP_XX_INI_SCAN_DIR` は `home/zsh.nix` の `initContent` にハードコードしているため、PHP バージョン追加時はそこを更新する。
- **シークレット**（SSH 鍵など）はコミットしない。
- 移行の経緯と方針は [CLAUDE.md](./CLAUDE.md) を参照。
