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
| work-api の worktree / コンテナ掃除 | Home Manager `launchd.agents`（1 時間ごと、`home/scripts/worktree-gc.sh`） |
| 再起動で止まった Claude の再開、Needs decision で会話が開いていないカードの開き直し（同じセッションには 1 回だけ。人が閉じたタブは開き直さない） | Home Manager `launchd.agents`（ログイン時と 3 分ごと、`home/scripts/agent-resume.sh`）＋ SessionStart hook `agents/claude/hooks/session-marker.sh` |
| Claude Code の auto memory の整理（重複・陳腐化・共有への移動、昇格は 1 件ずつ PR） | Home Manager `launchd.agents`（毎日 04:30、`home/scripts/memory-maintenance.sh`）。設計は `docs/memory-maintenance-design.md` |
| CLI パッケージ | nixpkgs `home.packages` |
| GUI アプリ | nix-darwin `homebrew.casks` |
| Dock / Finder / キーボード / スクリーンショット | nix-darwin `system.defaults` |
| Claude Code の設定 | `agents/claude/` に実体を置き手動コピー（Nix 管理外） |
| Codex の設定 | 手で書いた設定と branch-guard は nix-darwin `environment.etc` で `/etc/codex/`（system 層、`modules/codex.nix`）。`AGENTS.md` は Home Manager の out-of-store symlink。Codex が自分で書く状態は `~/.codex/config.toml` に残す |
| Claude Code / Codex のスキル | `agents/` に実体を置き、Home Manager がスキルごとに out-of-store symlink（`home/agent-skills.nix`） |
| Claude Code のエージェント定義 | `agents/claude/agents/` を `~/.claude/agents` へ out-of-store symlink（`home/agent-skills.nix`）。複数リポジトリの入口になる `orchestrator` は Orca の folder workspace で `claude --agent orchestrator` |
| シークレット、アプリデータ、ブラウザデータ | Keychain / 1Password / バックアップ |

## 構成

```text
.
├── flake.nix
├── flake.lock
├── agents/
│   ├── skills/           # Claude Code と Codex の両方: commit pr next fix-ci sync-pr
│   │                     # close-issue verify-no-regression defer-to-issue research memory-triage
│   ├── claude/
│   │   ├── settings.json # 権限・フック・ステータスライン
│   │   ├── CLAUDE.md     # グローバル指示
│   │   ├── statusline.py # 2行ステータスライン
│   │   ├── usage-report.py # 直近 N 日のトークン消費を API 定価換算で集計 (python3 で直接実行)
│   │   ├── agents/       # エージェント定義: orchestrator
│   │   ├── skills/       # Claude Code だけ: review-pr-comments
│   │   └── hooks/        # branch-guard.sh question-guard.sh session-marker.sh herdr-agent-state.sh
│   └── codex/
│       ├── AGENTS.md     # Codex のグローバル指示
│       ├── config.toml   # Codex の system 層 (/etc/codex/config.toml)
│       └── skills/       # Codex だけ: frontend-live-verify, review-pr-comments
├── home/
│   ├── default.nix
│   ├── agent-skills.nix  # スキルとエージェント定義の symlink
│   ├── git.nix
│   ├── ghostty.nix
│   ├── herdr.nix
│   ├── mise.nix
│   ├── neovim.nix
│   ├── packages.nix
│   ├── worktree-gc.nix
│   ├── pr-dispatch.nix
│   ├── agent-resume.nix
│   ├── memory-maintenance.nix
│   ├── zsh.nix
│   ├── scripts/
│   │   ├── worktree-gc.sh
│   │   ├── pr-dispatch.sh
│   │   ├── agent-resume.sh
│   │   └── memory-maintenance.sh  (+ -prompt.md, -schema.json)
│   └── config/
│       ├── ghostty/config
│       ├── herdr/config.toml
│       ├── nvim/
│       └── starship.toml
├── modules/homebrew.nix
├── modules/codex.nix     # /etc/codex/{config.toml,hooks.json}
├── system/defaults.nix
└── docs/migration-audit.md
```

マシンごとの差分（設定名・macOS の short user name・クローン先）は `flake.nix` の
`darwinConfigurations` に `mkDarwin` の引数として並べる。

| 設定名 | ユーザー名 | クローン先 |
|---|---|---|
| `work` | `wadakatu` | `~/www/personal/dotfiles` |
| `personal` | `koyoisono` | `~/Documents/Programming/dotfiles` |

新しい Mac を足すときは `mkDarwin { ... }` を1つ追加する。以下の `<name>` は該当する設定名に読み替える。
flake は純粋評価なので `$USER` を実行時に読んで切り替えることはしない（`--impure` が必要になるため）。

## 前提

- Apple Silicon Mac
- 管理者権限
- 作業前のTime Machineまたは同等のバックアップ
- [Determinate Nix for macOS](https://docs.determinate.systems/getting-started/individuals/)
- [Homebrew](https://brew.sh/)

nix-darwinはHomebrew本体をインストールしないため、Homebrewは先に用意する。

## 新しい Mac の初回セットアップ

```bash
# クローン先は flake.nix の dotfilesPath と一致させる
git clone https://github.com/wadakatu/dotfiles.git ~/www/personal/dotfiles
cd ~/www/personal/dotfiles

# 評価とビルド。ユーザー環境にはまだ適用しない
nix flake check --no-update-lock-file path:. --show-trace
nix build path:.#darwinConfigurations.<name>.system --no-link --show-trace
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
  switch --flake .#<name>
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
darwin-rebuild build --flake .#<name>

# 確認後に適用
sudo darwin-rebuild switch --flake .#<name>

# input更新。lockfile差分とビルド結果を確認してから適用する
nix flake update
nix flake check --show-trace
darwin-rebuild build --flake .#<name>
```

新しいNixファイルはGitの追跡対象でないとflakeから見えない。追加後はビルド前に
`git add <file>` する。

## エージェントの設定とスキル

Claude Code と Codex の設定・自作スキルは `agents/` に実体を置き、リポジトリを正とする。

### 設定（手動コピー）

設定は Nix 管理ではなく、home 側へ手動コピーして反映する（Claude に依頼してもよい）。
Claude Code の設定を Nix の `home.file` でシンボリックリンクにしないのは、`~/.claude`
配下が読み取り専用になると Claude Code 自身（`/config`、権限ダイアログの「常に許可」、
プラグイン導入）が設定を書き換えられなくなるため。

| リポジトリ | 配置先 |
|---|---|
| `agents/claude/settings.json` | `~/.claude/settings.json`（`settings.private.json` と合成） |
| `agents/claude/CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `agents/claude/statusline.py` | `~/.claude/statusline.py` |
| `agents/claude/hooks/` | `~/.claude/hooks/` |

Codex の設定は手動コピーしない（「Codex の設定」を参照）。

```bash
mkdir -p ~/.claude/hooks
cp -f agents/claude/CLAUDE.md agents/claude/statusline.py ~/.claude/
[ -f ~/.claude/settings.private.json ] || echo '{}' > ~/.claude/settings.private.json
[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
# Orca が ~/.claude/settings.json に直接書く hook (~/.orca/agent-hooks/ を呼ぶもの) は
# リポジトリに無い。jq の * は配列を置き換えるので、今のファイルから拾ってイベントごとに足し戻す。
jq -s '
  (.[2].hooks // {} | map_values(map(select(any(.hooks[]?; (.command // "") | test("\\.orca/agent-hooks/"))))) | with_entries(select(.value != []))) as $orca
  | (.[0] * .[1])
  | reduce ($orca | to_entries[]) as $e (.; .hooks[$e.key] += $e.value)
' agents/claude/settings.json ~/.claude/settings.private.json ~/.claude/settings.json > ~/.claude/settings.json.new && mv ~/.claude/settings.json.new ~/.claude/settings.json
# true になること。false なら `orca agent hooks on` で入れ直す
orca agent hooks status --json | jq '.result.statuses[] | select(.agent == "claude") | .managedHooksPresent'
chmod +x ~/.claude/statusline.py
cp agents/claude/hooks/*.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

### スキル（Home Manager の symlink）

スキルは `home/agent-skills.nix` が、スキルごとに作業ツリーの実体へ out-of-store symlink を張る。
実体を直接指すので読み取り専用にはならず、スキルを直すと rebuild なしで両方のエージェントに効く。
スキルを足したり消したりしたときだけ `darwin-rebuild switch` する。

| リポジトリ | 配置先 |
|---|---|
| `agents/skills/<name>/` | `~/.claude/skills/<name>` と `~/.agents/skills/<name>`（Claude Code と Codex の両方） |
| `agents/claude/skills/<name>/` | `~/.claude/skills/<name>`（Claude Code だけ） |
| `agents/claude/agents/` | `~/.claude/agents`（ディレクトリごと。Claude Code のエージェント定義） |
| `agents/codex/skills/<name>/` | `~/.agents/skills/<name>`（Codex だけ） |
| `agents/codex/AGENTS.md` | `~/.codex/AGENTS.md`（Codex のグローバル指示） |

- Codex が読む個人用スキルの場所は `~/.agents/skills`（[Codex のスキル](https://learn.chatgpt.com/docs/build-skills.md)）。`~/.codex/skills` は使わない。
- 同じ名前のスキルを Claude Code 用と Codex 用で分けたいときは、`agents/skills/` ではなく `agents/claude/skills/` と `agents/codex/skills/` に置く（例: review-pr-comments）。
- `SKILL.md` の frontmatter には `name` と `description` を書く（Codex は両方が必須）。
- `~/.claude/skills` と `~/.agents/skills` はディレクトリごとは管理しない。`~/.claude/skills/synced`（claude.ai から同期したスキル）や Orca が入れる `orca-cli` が同じ場所に置かれるため。
- 初めて rebuild するとき、リンクを張る場所に実ディレクトリ（以前の手動コピー）が残っていると Home Manager が止まる。先に消しておく。
- 使わない skill も一覧に載るだけで毎ターン文脈を使う。`/skill-doctor` で一度も使っていないものを見つけ、`settings.json` の `skillOverrides` で外す。claude.ai から同期される skill（`anthropic-skills:*`）は手元で消しても再同期されるので、ここで `user-invocable-only`（Claude の一覧からは消え、`/名前` では使える）にする。プラグインの skill には効かない。

`settings.json` にはステータスライン、権限ルール、フック登録がまとまっている。
`branch-guard.sh`（保護ブランチ main / master / dev 上での `git commit` / `git push` と、
保護ブランチを push 先に指名するコマンドをブロックする PreToolUse フック）も
登録済みなので、コピー以外の手作業は不要。

`~/.claude/settings.private.json` は公開しない設定を置く overlay。`autoMode` の社内向け
ルールや `skipDangerousModePermissionPrompt` のようなマシン固有の安全設定はここに書き、
上の `jq` がリポジトリ側の `settings.json` に重ねて `~/.claude/settings.json` を作る
（同じキーは overlay が勝つ）。リポジトリの `settings.json` には入れない。
Claude Code が自分で書き足したキー（例: `skipWorkflowUsageWarning`）はコピーで消えるので、
残したいものは overlay に移しておく。

`~/.claude/settings.local.json` は Claude Code が権限の「常に許可」を書き込む
ローカル専用ファイル。リポジトリには取り込まない。

home 側で直接編集した場合は同じ対応でリポジトリへ取り込み直す。ここにないスキル
（herdr、hatch-pet など外部配布物や実験中のもの）はローカル管理のままとする。

## Codex の設定

Codex は設定を層で重ねる。優先度の高い順に CLI 引数 > プロジェクトの `.codex/config.toml` >
profile > user（`~/.codex/config.toml`）> system（`/etc/codex/config.toml`）
（[Configuration precedence](https://learn.chatgpt.com/docs/config-file/config-basic)）。
`~/.codex/config.toml` には手で書いた設定と、Codex・Desktop が自分で書く状態（projects の trust、
hooks.state、plugins、tui、desktop、`notify` など）が混ざるので、手で書いた部分だけを system 層に置く。

| リポジトリ | 配置先 | 方法 |
|---|---|---|
| `agents/codex/config.toml` | `/etc/codex/config.toml` | nix-darwin `environment.etc`（`modules/codex.nix`） |
| `agents/claude/hooks/branch-guard.sh` | `/etc/codex/hooks.json` の PreToolUse | 同上。スクリプトは store に固定 |
| `agents/codex/AGENTS.md` | `~/.codex/AGENTS.md` | Home Manager の out-of-store symlink |

- **user 層が勝つ**。system 層に置いたキーが `~/.codex/config.toml` にも残っていると、user 側の値が黙って使われる。
  `/model` や Desktop の設定画面は user 層に書き戻すので、ときどき下の重複チェックを回す。
- テーブルはキー単位でマージされ、system 層のエントリ（例: `network.domains`）は user 層から消せない。外すときはリポジトリを直して rebuild する。
- `/etc/codex/config.toml` は誰でも読め、このリポジトリも公開なので、トークンや社内の値は置かない（user 層に書く）。
- サンドボックス内の通信は `network.domains` のドメインだけ（`features.network_proxy`）。それ以外は `CONNECT tunnel failed, response 403` で止まるので、
  必要なら domains に足す。proxy は HTTP(S) だけなので、SSH の git remote はサンドボックス内では使えない（今の remote はすべて HTTPS）。
  確認: `codex sandbox -P local-dev -- curl -sS -o /dev/null -w '%{http_code}' https://example.com` が 403 で失敗すればよい。
- system 層の hook は managed 扱いで、`/hooks` の trust が要らず、`/hooks` から無効化もできない
  （[Hooks](https://learn.chatgpt.com/docs/hooks)）。branch-guard を直したら rebuild で反映する。
- 確認: `codex --strict-config doctor --summary` の `config` が ✓（知らないキーがあると ⚠）、TUI の `/status` と `/hooks`。

重複チェック（何も出なければよい）:

```bash
python3 -I -c '
import tomllib
def flat(d, p=""):
    for k, v in d.items():
        q = f"{p}.{k}" if p else k
        yield from flat(v, q) if isinstance(v, dict) else [q]
sys_ = set(flat(tomllib.load(open("/etc/codex/config.toml", "rb"))))
usr = set(flat(tomllib.load(open("'"$HOME"'/.codex/config.toml", "rb"))))
print("\n".join(sorted(sys_ & usr)))'
```

### 現 Mac での移行（1 回だけ）

`switch` の直後は、手で書いた設定が user 層にも残っているので挙動は変わらない。branch-guard だけは
system 層と `~/.codex/hooks.json` の両方から 2 回実行される（どちらも止めるだけなので害はない）。

1. Codex の書き込み元を止める: Desktop と TUI を終了し、Orca / herdr の中の Codex セッションを閉じ、
   `codex app-server daemon stop`。
2. バックアップを取る（上書きしないよう日時付き）。今の世代番号も控える。
   ```bash
   b=~/.codex/backups/system-layer-$(date +%Y%m%d-%H%M%S) && mkdir -p "$b" && \
     cp -p ~/.codex/config.toml ~/.codex/hooks.json ~/.codex/AGENTS.md ~/.codex/hooks/branch-guard.sh "$b"/ && echo "$b"
   readlink /nix/var/nix/profiles/system   # 今の世代 (system-<番号>-link)。--list-generations は root でないと lock で失敗する
   ```
3. `sudo darwin-rebuild switch --flake .#<name>`。`ls -l /etc/codex/ ~/.codex/AGENTS.md` でリンクを確認する
   （`~/.codex/AGENTS.md.before-hm` は Home Manager が退避した旧ファイル）。
4. `~/.codex/config.toml` から `agents/codex/config.toml` にあるキーを消す（トップレベルの 7 キーと、
   `[features]`、`[permissions.local-dev]` 以下、`[mcp_servers.openaiDeveloperDocs]`）。重複チェックが空になればよい。
5. `~/.codex/hooks.json` の PreToolUse から branch-guard のグループ（`~/.codex/hooks/branch-guard.sh` を呼ぶもの）を消す。
   後ろの Orca の hook の位置がずれて trust が外れるので、次の手順で trust し直す。
6. `codex` を起動し、`/hooks` で branch-guard が managed と表示されること、Orca の PreToolUse を trust し直すこと、
   `/status` でモデルと承認がリポジトリの値になっていることを確かめる。
7. 使い捨てのリポジトリで branch-guard が止めることを確かめる。CLI、Desktop、Orca の中の Codex のそれぞれで、
   次のリポジトリで「`git commit --allow-empty -m test` を実行して」と頼み、`branch-guard:` で拒否されればよい。
   Orca のカードに Codex の状態（作業中・完了）が出ることも見る。
   ```bash
   git init -b main /tmp/guard-test
   ```
8. 全部通ったら完了。バックアップは数日使って問題がなければ消す。

どれかが通らなければ戻す: `sudo darwin-rebuild switch --rollback`（手順 2 で控えた世代に戻る）のあと、
手順 2 のバックアップから 4 ファイルを元の場所へ書き戻す（`AGENTS.md` は rollback で symlink が消えたあとに戻す）。

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
絶対パスの文字列を渡している
（[home-manager#2085](https://github.com/nix-community/home-manager/issues/2085)）。
このため、このリポジトリのクローン先は `flake.nix` の `mkDarwin` に渡す
`dotfilesPath` と一致させる。launchd のスクリプト（worktree-gc / pr-dispatch）も
同じ値を見るので、クローン先を変えるときは `dotfilesPath` を直して
`darwin-rebuild switch` する。

なお、herdr が書き換え時に「一時ファイル + rename」方式を使う場合は
`~/.config/herdr/config.toml` の symlink 自体が実ファイルに置き換わり、リポジトリから
切り離される。設定を変えたのに `git status` に出ないときはこれを疑い、
`ls -l ~/.config/herdr/config.toml` で symlink のままか確認する。

エージェント状態検知のフック `agents/claude/hooks/herdr-agent-state.sh` は
`herdr integration install claude` が生成するもので、こちらは他の Claude Code の設定と
同じく手動コピー運用。

## worktree / コンテナの自動掃除

work-api（`~/www/<work>`）の worktree は放置すると 1 つにつき nginx / php-fpm /
redis の 3 コンテナと bridge network を持ち続け、docker のサブネットプールが枯れて
`make up` が落ちる。`home/worktree-gc.nix` が定義する LaunchAgent が毎時 0 分に
`home/scripts/worktree-gc.sh` を回してこれを掃除する。

削除は次を **全て** 満たす worktree だけ。1 つでも欠ければ残す。

| 条件 | 意図 |
|---|---|
| main worktree ではない | 本体は対象外 |
| `git status --porcelain` が空 | 未コミットの作業を消さない |
| ディレクトリの mtime が 24 時間より古い | 稼働中のエージェントが作った直後のものを除外 |
| upstream が remote から消えている（= PR が merge / close 済み）<br>または detached かつ `origin/dev` から辿れる | 固有のコミットを持たないものだけ消す |

Orca の worktree（`~/orca/workspaces/` 配下、全リポジトリ）は上の表とは別に判定し、
`orca worktree rm` で消す。こちらも次を **全て** 満たすものだけ。

| 条件 | 意図 |
|---|---|
| ブランチ上にいる（detached ではない）、かつデフォルトブランチではない | PR で判定できないものは残す |
| `git status --porcelain` が空 | 未コミットの作業を消さない |
| 中のエージェントが全員 `done`（`orca worktree ps`） | 作業中・入力待ちのものを消さない |
| ブランチの PR があり、OPEN が 1 本も無い（MERGED / CLOSED） | PR が終わったものだけ消す |
| PR に入っていないローカルコミットが無い（件名で照合） | squash merge 後でも固有のコミットを消さない |

Orca のボードの Done 列（pr-dispatch がマージ済みのカードを移す）は判定に使わない。

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
DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/worktree-gc.sh   # 消さずに判定だけ出す
tail -50 ~/Library/Logs/worktree-gc.log                # 直近の実行ログ
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.worktree-gc  # 即時実行
```

閾値や除外を変えるだけなら `darwin-rebuild` は不要（plist はリポジトリの絶対パスを
直接叩いているため）。実行時刻を変えるときだけ `worktree-gc.nix` を直して rebuild する。

## auto memory の自動整理

Claude Code の auto memory（`~/.claude/projects/<p>/memory/`）と、全リポ共通の共有メモリ
（`~/.claude-shared-memory/`、`agents/claude/CLAUDE.md` が `@import` する）を、`home/memory-maintenance.nix`
の LaunchAgent が毎日 04:30 に `home/scripts/memory-maintenance.sh` で整理する。設計と判断の経緯は
`docs/memory-maintenance-design.md`。

- 各 memory dir を git で snapshot し、前回以降に変わったファイルだけを `claude -p --restricted` に整理させる。
  変化が無ければ AI は起動しない。AI ができるのは作業領域の読み取りと、memory の写しの編集だけ。
- 自動で行うのは、説明の短縮・重複の統合・根拠のある事実の更新・根拠のある陳腐化の削除・共有への移動。
  feedback 型は単独では消さない。保守の間に対話セッションが書き換えたファイルは写さず翌日に回す。
- グローバル（dotfiles）やリポの rules への昇格は、1 日 5 件まで 1 件ずつ PR にする（Orca に worktree を作るので、
  その後の CI・レビュー対応は pr-dispatch が行う）。dotfiles は公開リポなので、push の前に社内情報を検査する。
- PR がマージされて昇格先に見えたら、元のメモリを縮小・削除し、`[[name]]` のリンクを書き換える。
- 全件の見直しが 28 日以上前の dir を、1 日 1 つ全件見直す。

```bash
DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/memory-maintenance.sh    # 何も書かず、対象と lint だけ出す
~/www/personal/dotfiles/home/scripts/memory-maintenance.sh full <p> [--seed <file>]  # 1 つの dir を今すぐ全件見直す
tail -50 ~/Library/Logs/memory-maintenance.log
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.memory-maintenance   # 即時実行
```

状態は `~/Library/Application Support/memory-maintenance/`（`cursor/`、`full-done/`、`proposals/<id>.json`、
`runs/`、`needs-human.md`）。

戻し方:

- 保守の変更は memory dir ごとに `maintenance: ...` のコミットになっている。
  `git -C <memory dir> log --oneline` で探し、`git -C <memory dir> revert --no-edit <sha>` で戻す。
- 共有への移動は、共有側と元の dir の 2 つのコミットになっている。元側だけ戻すと重複が残るだけで、内容は失われない。
- 提案を取り下げるには `proposals/<id>.json` を消す。

## シークレットと移行対象外データ

次のデータはコミットしない。

- API token、PAT、秘密鍵、`.env*`
- GitHub CLIやGoogle Cloud SDKの認証情報
- SSH / GPG秘密鍵
- Herd、Docker、ブラウザ、各GUIアプリのユーザーデータ

これらはKeychain、1Password、Time Machine、各サービスへの再ログインで移行する。
