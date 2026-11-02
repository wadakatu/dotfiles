# gcloud と auto mode の分類器

- 書き込み系の gcloud（`gcloud run jobs update` / `gcloud run jobs execute` など、実リソースを変えるもの）は auto mode の分類器に止められる。
  読み取り系（`describe`、`gcloud logging read`、`gcloud secrets list`）は通る。
- 読み取りでも止められるものがある。`gcloud secrets versions access`（secret の値）と、本番プロジェクトの
  `gcloud secrets versions list`（値を読まないメタデータでも「Production Reads」として拒否される）。
  本番の secret の確認は、最初からコマンドを提示してユーザーに `!` で実行してもらう。
- クラウド上の実機検証が要る作業は、最初から「読み取りは自分で実行し、書き込みを含む手順は 1 本のスクリプトにして
  ユーザーに `! bash <path>` で実行してもらう」前提で組む。
- そのスクリプトには次を入れる。
  - 危険な前提が崩れていたら中断する（未適用の migration がある、必要な権限が無い など）
  - 定義を一時的に変えたら `trap ... EXIT` で必ず戻す
  - 判定に使う証跡（ログ本文・経過秒数）を出力に含める（こちらからは実行中のログが見えない）

**Why:** 止められてから手順を組み直すと二度手間になる。本番の読み取りは「聞かずに進めてよい」範囲でも、secret まわりは分類器が別扱いにする。
