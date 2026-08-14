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
| herdr の設定 | `home/config/herdr/config.toml` を Home Manager が out-of-store symlink（本体は Nix 管理外） |
| studio-api の worktree / コンテナ掃除 | Home Manager `launchd.agents`（1 日 2 回、`home/scripts/worktree-gc.sh`） |
| CLI パッケージ | nixpkgs `home.packages` |
| GUI アプリ | nix-darwin `homebrew.casks` |
| Dock / Finder / キーボード / スクリーンショット | nix-darwin `system.defaults` |
| Claude Code / Codex の設定・スキル・コマンド | `agents/` に実体を置き手動コピー（Nix 管理外） |
| シークレット、アプリデータ、ブラウザデータ | Keychain / 1Password / バックアップ |

## 構成

```text
.
├── flake.nix
├── flake.lock
├── agents/
│   ├── claude/
│   │   ├── settings.json # 権限・フック・ステータスライン
│   │   ├── CLAUDE.md     # グローバル指示
│   │   ├── statusline.py # 2行ステータスライン
│   │   ├── commands/     # /commit /pr /review-pr-comments /next /fix-ci
│   │   │                 # /sync-pr /verify-no-regression /close-issue
│   │   ├── skills/       # defer-to-issue, research, memory-triage
│   │   └── hooks/        # branch-guard.sh
│   └── codex/
│       └── skills/       # frontend-live-verify, review-pr-comments
├── home/
│   ├── default.nix
│   ├── git.nix
│   ├── ghostty.nix
│   ├── herdr.nix
│   ├── mise.nix
│   ├── neovim.nix
│   ├── packages.nix
│   ├── worktree-gc.nix
│   ├── zsh.nix
│   ├── scripts/
│   │   └── worktree-gc.sh
│   └── config/
│       ├── ghostty/config
│       ├── herdr/config.toml
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
nix flake check --no-update-lock-file path:. --show-trace
nix build path:.#darwinConfigurations.mymac.system --no-link --show-trace
```

Determinate NixのmacOSパッケージは、インストール時に
`/etc/nix/nix.custom.conf`を通常ファイルとして作成する。一方、この構成は
`determinateNix.customSettings`で同じファイルをnix-darwinの管理対象にするため、
初回activationの前に既存設定を確認して管理を引き継ぐ。

次のコマンドはコメントと空行を除いた設定キーだけを表示し、値は表示しない。

```bash
sudo awk -F= '/^[[:space:]]*($|#)/{next}{key=$1;gsub(/^[[:space:]]+|[[:space:]]+$/,"",key);print key}' /etc/nix/nix.custom.conf
```

何も表示されなければ、既存ファイルを削除せずバックアップ名へ退避する。

```bash
sudo mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
```

設定キーが表示された場合は退避前に止まり、必要な設定を
`determinateNix.customSettings`へ移植する。トークン等の値はGitへコミットしない。

初回だけ`nix run`で`darwin-rebuild`を起動する。`sudo -H`でrootの`HOME`を
`/var/root`にし、ユーザーHOMEの所有権警告を避ける。

```bash
sudo -H /nix/var/nix/profiles/default/bin/nix run nix-darwin/master#darwin-rebuild -- \
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

## エージェントスキルとコマンド

Claude Code と Codex の設定・自作スキル・コマンドは `agents/` に実体を置く。Nix 管理では
なくリポジトリを正とし、home 側へ手動コピーして反映する（Claude に依頼してもよい）。

Claude Code の設定を Nix の `home.file` でシンボリックリンクにしないのは、`~/.claude`
配下が読み取り専用になると Claude Code 自身（`/config`、権限ダイアログの「常に許可」、
プラグイン導入）が設定を書き換えられなくなるため。

| リポジトリ | 配置先 |
|---|---|
| `agents/claude/settings.json` | `~/.claude/settings.json` |
| `agents/claude/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `agents/claude/statusline.py` | `~/.claude/statusline.py` |
| `agents/claude/skills/` | `~/.claude/skills/` |
| `agents/claude/commands/` | `~/.claude/commands/` |
| `agents/claude/hooks/` | `~/.claude/hooks/` |
| `agents/codex/skills/` | `~/.codex/skills/` |

```bash
mkdir -p ~/.claude/skills ~/.claude/commands ~/.claude/hooks ~/.codex/skills
cp -f agents/claude/settings.json agents/claude/CLAUDE.md agents/claude/statusline.py ~/.claude/
chmod +x ~/.claude/statusline.py
cp -R agents/claude/skills/* ~/.claude/skills/
cp agents/claude/commands/*.md ~/.claude/commands/
cp agents/claude/hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
cp -R agents/codex/skills/* ~/.codex/skills/
```

`settings.json` にはステータスライン、権限ルール、フック登録がまとまっている。
`branch-guard.sh`（保護ブランチ main / master / dev 上での `git commit` / `git push` と、
保護ブランチを push 先に指名するコマンドをブロックする PreToolUse フック）も
登録済みなので、コピー以外の手作業は不要。

`~/.claude/settings.local.json` は Claude Code が権限の「常に許可」を書き込む
ローカル専用ファイル。リポジトリには取り込まない。

home 側で直接編集した場合は同じ対応でリポジトリへ取り込み直す。ここにないスキル
（herdr、hatch-pet など外部配布物や実験中のもの）はローカル管理のままとする。

## herdr の設定

herdr（AI コーディングエージェント用のターミナルワークスペースマネージャ）本体は
`herdr update` が自前で `~/.local/bin` を更新するため Nix 管理外。設定ファイルだけを
`home/config/herdr/config.toml` に置き、`home/herdr.nix` から Home Manager の
`mkOutOfStoreSymlink` で `~/.config/herdr/config.toml` へリンクする。

Ghostty のように `.source = ./config/...` としないのは、herdr が config.toml を
自分で書き換えるため。`/nix/store` への読み取り専用リンクにすると、オンボーディング
完了時の `onboarding = false` 書き込みや `herdr config reset-keys` が失敗する
（`~/.claude` を symlink にしない理由と同じ）。

`mkOutOfStoreSymlink` は `/nix/store` を経由せず指定した絶対パスへ直接リンクを張る
ヘルパー。実体はリポジトリ側の1ファイルだけになるので、

- herdr 自身の書き換えが通り、その差分がそのまま `git status` に出る
- 設定をいじるたびに `darwin-rebuild switch` する必要がない（`herdr server reload-config`
  だけで反映される）

flake では相対パスを渡すと flake source の store コピーを指してしまうため、
`config.home.homeDirectory` を使った絶対パスの文字列を渡している
（[home-manager#2085](https://github.com/nix-community/home-manager/issues/2085)）。
このため、このリポジトリのクローン先は `~/www/dotfiles` である前提。

なお、herdr が書き換え時に「一時ファイル + rename」方式を使う場合は
`~/.config/herdr/config.toml` の symlink 自体が実ファイルに置き換わり、リポジトリから
切り離される。設定を変えたのに `git status` に出ないときはこれを疑い、
`ls -l ~/.config/herdr/config.toml` で symlink のままか確認する。

エージェント状態検知のフック `agents/claude/hooks/herdr-agent-state.sh` は
`herdr integration install claude` が生成するもので、こちらは他の Claude Code 設定と
同じく手動コピー運用。

## worktree / コンテナの自動掃除

studio-api（`~/www/dev/app`）の worktree は放置すると 1 つにつき nginx / php-fpm /
redis の 3 コンテナと bridge network を持ち続け、docker のサブネットプールが枯れて
`make up` が落ちる。`home/worktree-gc.nix` が定義する LaunchAgent が毎日 12:00 と
21:00 に `home/scripts/worktree-gc.sh` を回してこれを掃除する。

削除は次を **全て** 満たす worktree だけ。1 つでも欠ければ残す。

| 条件 | 意図 |
|---|---|
| main worktree ではない | 本体は対象外 |
| `git status --porcelain` が空 | 未コミットの作業を消さない |
| ディレクトリの mtime が 24 時間より古い | 稼働中のエージェントが作った直後のものを除外 |
| upstream が remote から消えている（= PR が merge / close 済み）<br>または detached かつ `origin/dev` から辿れる | 固有のコミットを持たないものだけ消す |

ただし `~/.herdr/worktrees/` 配下は条件を満たしても**自動削除しない**。herdr が自前で
workspace 状態を持っており `git worktree remove` を直接叩くと食い違うため、候補として
ログに出すだけに留める（削除は `herdr worktree remove --workspace <ID> --force`）。

`git worktree remove` はブランチを消さないので、コミットは常に残る。コンテナ側は
`app-app-` / `app-worktree-` で始まる compose プロジェクトだけを対象にし、共有インフラ
（mysql、traefik、grafana…）や他リポジトリ（`docker-*`、`studio-*`）、本体の `app` には
触らない。working_dir が既に消えている孤児プロジェクトも同時に落とす。

ディスク回収は dangling image / volume と 168 時間より古い build cache のみ。
`docker image prune -a` を毎日回すと `api-base` が消えて `make build` のたびに
再 pull になるため使わない。

手で確認・実行する場合:

```bash
DRY_RUN=1 ~/www/dotfiles/home/scripts/worktree-gc.sh   # 消さずに判定だけ出す
tail -50 ~/Library/Logs/worktree-gc.log                # 直近の実行ログ
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.worktree-gc  # 即時実行
```

閾値や除外を変えるだけなら `darwin-rebuild` は不要（plist はリポジトリの絶対パスを
直接叩いているため）。実行時刻を変えるときだけ `worktree-gc.nix` を直して rebuild する。

## シークレットと移行対象外データ

次のデータはコミットしない。

- API token、PAT、秘密鍵、`.env*`
- GitHub CLIやGoogle Cloud SDKの認証情報
- SSH / GPG秘密鍵
- Herd、Docker、ブラウザ、各GUIアプリのユーザーデータ

これらはKeychain、1Password、Time Machine、各サービスへの再ログインで移行する。
