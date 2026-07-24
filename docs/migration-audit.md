# Mac migration audit

新しい Mac をクリーンに構築するための棚卸し記録。
調査日は 2026-07-22。実体を削除する前に、宣言側の更新とビルド確認を完了する。

## 基本方針

- CLI・シェル・Git・エディタ設定は原則 Nix / Home Manager で管理する。
- 1Password CLI は公式macOS手順とデスクトップアプリ連携を優先し、例外としてHomebrew caskで管理する。
- GUI アプリは Homebrew cask、言語ランタイムは mise、PHP は Herd で管理する。
- 認証情報は macOS Keychain / 1Password に置き、dotfiles や常時有効な環境変数へ入れない。
- `homebrew.onActivation.cleanup` は棚卸し完了まで `"none"` を維持する。
- 削除は dry-run と個別確認を挟み、宣言の更新とは別工程で行う。

## 確定事項

### 継続利用

- ユーザー名: `wadakatu`
- Apple Silicon (`aarch64-darwin`)
- zsh
- mise（Bun / Node.js / pnpm / Python / Yarn）
- Herd（PHP / Composer）
- Neovim + lazy.nvim
- Starship
- Ghostty
- GitHub CLI の Keychain 認証
- Google Cloud CLI
- tenv（Terraformのバージョン管理）
- uv（Pythonの依存関係・仮想環境・CLI管理）
- yq（YAML等の構造化データ処理）

### 削除対象

- Cursor.app
- `~/.local/bin/cursor-agent` と `~/.local/share/cursor-agent`
- Node.js グローバルパッケージ `ccusage`
- CodeRabbit CLI (`~/.local/bin/coderabbit` / `~/.local/bin/cr` / `~/.coderabbit`)
- iTerm2 (`/Applications/iTerm.app`)
- ChatGPT Classic.app
- ChatGPT Atlas.app
- 旧 Logi Options.app (`com.logitech.Logi-Options`)
- Postman.app
- Zoom (`/Applications/zoom.us.app`)
- Elgato Stream Deck.app
- Figma.app
- GarageBand.app
- Keynote.app
- Numbers.app
- Pages.app
- iMovie.app
- Linear.app
- Orca.app (`com.stablyai.orca`)
- Sequel Ace.app
- GitHub Desktop.app
- Google Chrome.app
- PhpStorm.app
- Flutter SDK（Homebrew cask `flutter`）
- ngrok（Homebrew cask `ngrok`）
- Bazelisk（Homebrew formula `bazelisk`）
- GNU Bison（Homebrew formula `bison`）
- Deno（Homebrew formula `deno`）
- FFmpeg（Homebrew formula `ffmpeg`。必要時のみ再導入）
- GnuPG（Homebrew formula `gnupg`。必要時のみ再導入）
- MySQL Client 8.0（Homebrew formula `mysql-client@8.0`）
- PHP 8.3（Homebrew formula `php@8.3`。PHPはLaravel Herdへ一本化）
- pkgconf（Homebrew formula `pkgconf`。必要な場合はパッケージ側の依存として導入）
- pngquant（Homebrew formula `pngquant`。必要時はImageMagickまたは再導入で対応）
- Protocol Buffers（Homebrew formula `protobuf`。必要なプロジェクトではBazel等の依存管理を利用）
- Python 3.13（Homebrew formula `python@3.13`。Pythonはmiseの最新安定版へ移管）
- re2c（Homebrew formula `re2c`。PHP本体開発時だけプロジェクト用途で再導入）
- Telnet（Homebrew formula `telnet`。疎通確認は`nc`、リモート接続は`ssh`を利用）

実体の削除は、設定移行と検証が完了するまで行わない。

### 宣言から外す候補

- Volta の環境変数と PATH（現環境は mise）
- Vim と動作確認用の system Vim（現環境は Neovim）
- 旧 Brewfile 由来の `gcc` / `libwebp`
- Herd PHP 7.4 の環境変数
- 現 Mac に存在しない `tableplus` / `chatwork` / `visual-studio-code`

## GUI アプリ棚卸し

`/Applications`、Homebrew cask、Dock の固定項目を 2026-07-22 に照合した。
Spotlight の最終使用日時は全アプリで取得できなかったため、使用頻度は推測しない。

### 継続候補（Dock 固定または継続利用を確認済み）

| アプリ | 判断根拠 | 宣言状況 |
| --- | --- | --- |
| 1Password | 継続利用確認済み、Dock 固定 | GUIとCLIをHomebrew cask宣言済み。認証情報は移行対象外 |
| ChatGPT（Codex統合app） | 継続利用確認済み、bundle ID `com.openai.codex` | GUIはHomebrew cask宣言済み |
| Claude | 継続利用確認済み、Dock 固定 | Homebrew cask宣言済み |
| Discord | 継続利用確認済み、Dock 固定 | Homebrew cask宣言済み |
| Docker Desktop | 継続利用確認済み、Dock 固定 | Homebrew cask宣言済み |
| Elgato Wave Link | マイク利用のため継続、Dock 固定 | Homebrew cask宣言済み |
| Ghostty | 継続利用確認済み、Dock 固定 | Homebrew cask 宣言済み |
| Herd | PHP / Composerの継続利用確認済み | Homebrew cask 宣言済み |
| Logi Options+ | 継続利用確認済み | Homebrew cask 宣言済み |
| Notion | 継続利用確認済み、Dock 固定 | Homebrew cask宣言済み |
| ScreenTune | 継続利用確認済み、Dock 固定 | Homebrew未対応。公式サイトから手動導入 |
| Slack | 継続利用確認済み、Dock 固定 | Homebrew cask宣言済み |
| Zen Browser | 継続利用確認済み | Homebrew cask `zen` を宣言済み |

### 不要確定

- Cursor.app
- iTerm2（Ghosttyへ移行済み。Homebrew cask宣言と旧プロファイルは削除済み）
- ChatGPT Classic（現行ChatGPT/Codex統合アプリへ移行済み）
- ChatGPT Atlas（Zen Browserへ移行するためHomebrew cask宣言から削除済み）
- 旧 Logi Options（Logi Options+へ移行済み）
- Postman（最近使用していない。Homebrew cask宣言から削除済み）
- Zoom（最近使用していない。Homebrew cask宣言から削除済み）
- Elgato Stream Deck（使用頻度が低いため移行対象外）
- Figma（デスクトップアプリを使用していないため移行対象外）
- GarageBand（使用していないため移行対象外）
- Keynote（使用していないため移行対象外）
- Numbers（なくても困らないため移行対象外）
- Pages（使用していないため移行対象外）
- iMovie（使用していないため移行対象外）
- Linear（使用していないため移行対象外）
- Orca（使用していないため移行対象外）
- Sequel Ace（使用していないため移行対象外）
- GitHub Desktop（Git CLI / GitHub CLIを利用するため移行対象外）
- Google Chrome（Zen Browserへ移行するためHomebrew cask宣言から削除済み）
- PhpStorm（最近使用していないためHomebrew cask宣言から削除済み）

Safari は macOS 標準アプリとして宣言管理の対象外とする。

App Store由来として確認できたGarageBand、Keynote、Numbers、Pages、Sequel Ace、iMovieはすべて移行対象外のため、`homebrew.masApps`は宣言しない。

### 現Mac限定（新しいMacへ移行しない）

- Karabiner-Elements / Karabiner-EventViewer
  - 壊れた内蔵キーボードを無効化するため、現在のMacでは継続利用する。
  - 新しいMacにはインストールせず、vendor/product IDを含む現設定も移植しない。

## CLIツール棚卸し

| ツール | 判断 | 宣言状況 |
| --- | --- | --- |
| 1Password CLI (`op`) | 継続利用。デスクトップアプリ連携とTouch ID認証を利用可能 | Homebrew cask `1password-cli`を宣言済み |
| age (`age` / `age-keygen`) | `agent-home-migrate` のbundleを公開鍵暗号化し、secret-capableなCodex・Claude設定を安全に移行するため継続利用 | Home Managerの`home.packages`へ宣言済み。旧Macで暗号化し、新Macで復号・検証する |
| Codex CLI (`codex`) | 継続利用。caskも公式GitHub Releaseのstandalone binaryを配置するため、再現性を優先してHomebrewを維持 | Homebrew cask `codex`を宣言済み。`~/.codex`の認証・履歴は管理対象外 |
| CodeRabbit CLI (`coderabbit` / `cr`) | 現在使っていないため移行対象外 | dotfilesには未宣言。端末固有の`coderabbit.machineId`も移植せず、CLI本体と`~/.coderabbit`は2026-07-24にゴミ箱へ退避済み |
| Flutter SDK (`flutter`) | 現在使っていないため移行対象外 | dotfilesには未宣言。現MacのHomebrew cask実体は削除工程まで維持 |
| ngrok (`ngrok`) | 現在使っていないため移行対象外 | dotfilesには未宣言。現MacのHomebrew cask実体は削除工程まで維持 |
| Bazelisk (`bazelisk`) | Bazelプロジェクトを使用していないため移行対象外 | dotfilesには未宣言。現MacのHomebrew formula実体は削除工程まで維持 |
| GNU Bison (`bison`) | パーサー生成やPHP等のソースビルドに使用しておらず、移行対象外 | dotfilesには未宣言。必要時はHomebrewのビルド依存として再導入する |
| Deno (`deno`) | 現在使っておらず、Denoプロジェクト設定も見つからないため移行対象外 | dotfilesとmiseには未宣言。Starshipの表示設定は本体に依存しないため維持 |
| FFmpeg (`ffmpeg`) | 使用頻度が低いため移行対象外。デモ動画からGIFを再生成するときだけ必要 | dotfilesには未宣言。必要時にHomebrewで再導入する |
| GitHub CLI (`gh`) | 継続利用 | Home Managerの`programs.gh.enable`で宣言済み。新Macでは`gh auth login`でKeychainへ再認証し、Homebrew版は移行しない |
| Google Cloud CLI (`gcloud`) | 継続利用 | Home Managerの`home.packages`へNixpkgsの`google-cloud-sdk`を宣言済み。旧`~/Downloads/google-cloud-sdk`は2026-07-24にゴミ箱へ退避し、認証情報はdotfilesに含めない |
| Glow (`glow`) | 使用頻度は低いが、Markdown閲覧用として継続利用 | Home Managerの`home.packages`へ宣言済み。Homebrew版は移行しない |
| GnuPG (`gpg`) | Git署名設定・公開鍵・秘密鍵・依存元がなく、現在は未使用と判断して移行対象外 | dotfilesには未宣言。署名検証や暗号化が必要になった場合のみ再導入する |
| ImageMagick (`magick`) | Codex・Claudeによる画像加工で使うため継続利用 | Home Managerの`home.packages`へ宣言済み。Homebrew版は移行しない。Herd内蔵Imagickとは別管理 |
| jq (`jq`) | 既存のデプロイ・テストスクリプトとCodex・ClaudeのJSON処理で使うため継続利用 | Home Managerの`home.packages`へ宣言済み。Homebrew版は移行しない |
| MySQL Client (`mysql` / `mysqldump`) | 現在の開発環境はDockerコンテナ内のクライアントを使うため移行対象外 | dotfilesには未宣言。Homebrew専用PATHも削除済み |
| Neovim (`nvim`) | 継続利用 | Home Managerの`programs.neovim.enable`で本体を宣言し、`init.lua`・プラグイン定義・`lazy-lock.json`も管理済み。Homebrew版は移行しない |
| PHP (`php`) | Laravel Herdで管理するため、Homebrewの`php@8.3`は移行対象外 | HerdをHomebrew caskで宣言済み。現在の`php`もHerd製PHP 8.4を参照し、`php@8.3`を使う導入済みformulaはない |
| pkgconf (`pkg-config`) | ホスト上でネイティブライブラリを手動ビルドする用途がなく、移行対象外 | dotfiles内の参照と実行時に依存する導入済みHomebrew formulaはない。`pngquant`のソースビルド時には使われるが、必要時はパッケージ側の依存として導入する |
| pngquant (`pngquant`) | PNGの専用非可逆圧縮を使用しておらず、移行対象外 | dotfiles内の参照と実行時に依存する導入済みHomebrew formulaはない。必要時はImageMagickを使うか個別に再導入する |
| Protocol Buffers (`protoc`) | ホストのコンパイラを直接使う`experiments/gapic-generator-php`は現在未使用のため移行対象外 | 導入済みHomebrew formulaからの依存はない。`w3c/ift-encoder`はBazel ModuleでProtobufを宣言しているため、プロジェクト側の依存管理に任せる |
| Python (`python` / `python3`) | Codex・Claudeの汎用処理で継続利用し、プレリリースを除く最新安定版を使用 | Home Managerのmiseグローバル設定へ`python = "latest"`を宣言済み。現在は3.14.6へ解決され、Homebrewの`python@3.13`は移行しない |
| re2c (`re2c`) | 常設せず、PHP本体開発が必要になった場合だけ再導入するため移行対象外 | `oss/php-src`以外に利用箇所と導入済みHomebrew formulaからの依存はない。必要時は`bison`・`autoconf`等とともにプロジェクト用途で導入する |
| Starship (`starship`) | 継続利用。Git・クラウド・コンテナ・言語ランタイム・コマンド実行時間の表示を活用 | Home Managerの`programs.starship.enable`で本体を宣言し、既存のTOML設定も管理済み。Homebrew版は移行しない |
| Telnet (`telnet`) | 利用箇所がなく、暗号化されないリモート接続も使用しないため移行対象外 | 導入済みHomebrew formulaからの依存はない。TCP疎通確認にはmacOS標準の`nc`、リモート接続には`ssh`を使う |
| tenv (`tenv` / `terraform`) | Terraformを継続利用し、プロジェクトの`required_version`に合わせてバージョンを切り替える | nix-darwinの`homebrew.brews`へ`tenv`を宣言済み。`~/.tenv`の既存バイナリは移行せず、新Macで必要なバージョンを再取得する |
| uv (`uv` / `uvx`) | Pythonプロジェクトの依存関係・仮想環境・一時CLI管理に継続利用 | Home Managerの`home.packages`へ宣言済み。Python本体はmiseで管理し、Homebrew版uvは移行しない |
| yq (`yq`) | Kubernetes・Docker Compose・CI設定等のYAML処理とCodex・Claudeの構造化編集に継続利用 | 現在と同じMike Farah版をNixpkgsの`yq-go`でHome Managerへ宣言済み。Homebrew版は移行しない |

## 現 Mac の移行対象外データ

以下は dotfiles にコミットせず、バックアップまたは再認証で移行する。

- macOS Keychain / 1Password
- GitHub CLI、Google Cloud SDK、各AIツールの認証情報
- SSH 秘密鍵
- Herd のサイト・データベース・証明書
- Docker のイメージ、ボリューム、コンテナ
- ブラウザプロファイル
- アプリ固有データとライセンス

## 容量整理候補

- `~/.npm`: 約 26 GB（`_cacache` 約 23 GB、`_npx` 約 3.2 GB）
- `~/.local/share/mise`: 約 12 GB（`mise ls --prunable` で 68 バージョン）
- `~/.bun`: 約 3.1 GB
- Homebrew: `brew cleanup --dry-run` で約 363 MB

プロジェクト配下に複数の `mise.toml` / `.tool-versions` があるため、mise の削除候補はプロジェクトごとに確認する。

## 移行前ゲート

- [ ] Time Machine または同等のバックアップを作成する
- [x] Home Manager のユーザー名とホームパスを `wadakatu` に統一する
- [x] 現行 zsh / Git / mise / Neovim / Starship / Ghostty 設定を宣言側へ移植する
- [x] `GITHUB_TOKEN=$(gh auth token)` をシェル起動処理から除外する
- [x] GUI アプリと Homebrew formula の採否を確定する
- [x] `nix flake check` を通す
- [ ] macOS runner で `darwinConfigurations.mymac.system` をビルドする
- [x] 現 Mac で `darwinConfigurations.mymac.system` をビルドする
- [x] ビルド結果を確認してから初回 `switch` を実行する
