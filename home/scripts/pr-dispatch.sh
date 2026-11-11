#!/usr/bin/env bash
#
# 自分の OPEN な PR を見て、対応が要るものに Orca のタブでエージェントを起動する。
# 対象は Orca に worktree がある非 draft の PR。設定で adopt_prs=true にすると、Orca に登録したリポの
# worktree の無い PR にも、対応が要るときに worktree を作る (下の「worktree の無い PR」の節)。
#   conflict → /sync-pr、CI 失敗 → /fix-ci、未対応のレビュー → /review-pr-comments
# あわせて、人の判断待ちになったものを Orca のボードに出す。
#   同じ対応を MAX_ATTEMPTS 回起動しても直らない PR → Needs decision
#   CLEAN で auto-merge の無い PR (マージするかは人が決める) → In review に置き、未読と「マージ可」を付ける
#   入力待ち (waiting) のエージェント → Needs decision
#   文章で質問して止まったエージェント (Orca では done に見える) → 未読と「要確認」のコメントだけ付ける
#   PR がマージ・クローズされた worktree → Done (worktree-gc が消すまでの置き場所)
# 設定で queue_repos と queue_label を書くと、そのリポで自分がラベルを付けた自分の issue (キュー) に、
# worktree を作って /issue-worker を起動する (下の「キュー」の節)。
# launchd からログイン時と数分ごとに実行される。定義は home/pr-dispatch.nix。
#
# 1 回の流れ: ロック → 再開 (agent-resume.sh) → 観測 (Orca と GitHub) → 再開待ちの解除 → PR 対応の起動 → キュー → ボード。
# 再開を先に、同じロックの中で動かすのは、再開するセッションと PR 対応のエージェントを同じ worktree に並べないため。
# 観測が欠けた回 (Orca や GitHub に届かない、一覧が途中で切れた) は何も起動しない。
# 結果の分からない起動は、自動ではやり直さない (起動できていたら 2 体並ぶ)。
#
# 止めるとき: ~/Library/Application Support/pr-dispatch/BRAKE を置く (空でよい)。再開と起動が止まり、ボードの更新は続く。
#
# 手で確認するとき (キューの対象外の issue と理由は VERBOSE=1 で出る):
#   DRY_RUN=1 VERBOSE=1 ~/www/personal/dotfiles/home/scripts/pr-dispatch.sh
#
# worker が着手の直前に呼ぶ再確認 (ラベルを付けた時刻 T の内容のまま進めてよいか。状態は何も書かない):
#   pr-dispatch.sh check <issue の番号> <T>   通れば ok を出して exit 0、止まるなら理由と exit 1、確かめられなければ exit 2
#
set -euo pipefail

# launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin だけで、orca も gh も jq も入らない。
# 後ろに足す (worktree-gc.sh と同じ)。テストが偽の orca / gh を先に効かせられるようにするため。
PATH="$PATH:/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
# launchd の環境にはロケールが無く、cut -c がバイト単位で切って日本語のコメントが文字化けする。
export LC_ALL=en_US.UTF-8

ORCA_ROOT="${ORCA_ROOT:-$HOME/orca/workspaces}"
# 状態の置き場所。テストはこの 1 つを一時ディレクトリに向ける (dispatch-lock.sh のコメントを参照)。
STATE_ROOT="${STATE_ROOT:-$HOME/Library/Application Support}"
# 起動済みの (PR, 対応, 状態) を 1 行ずつ覚える。直せなかった状態に周期ごと起動し直さないため。
# 状態が変われば (新しい push、新しいレビュー) キーが変わり、また起動する。
STATE_FILE="$STATE_ROOT/pr-dispatch/dispatched.tsv"
# ボードに書いた (worktree, 理由, 状態) を 1 行ずつ覚える。数分ごとに同じ状態を書き直して、
# 人が消した未読の印を付け直さないため。
BOARD_FILE="$STATE_ROOT/pr-dispatch/board.tsv"
# 1 回の実行で起動する上限。base の更新で conflict が一斉に出たときに、エージェントを並べすぎない。
MAX_LAUNCHES="${MAX_LAUNCHES:-3}"
# 同じ PR に同じ対応を起動する回数の上限。超えたら人に上げる (自動の修正が空回りし続けないため)。
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
# 起動の前後を 1 行ずつ足す (追記のみ)。<時刻> <launching|launched|lost|fail|unknown> <operationId|-> <PR> <対応> <状態>
# unknown は、結果が分からないまま LAUNCH_UNKNOWN_AFTER が過ぎて閉じた起動。
# 起動の返事を失ったときに、新しく起動し直さず、同じ依頼を出し直すための記録。
LAUNCHES_FILE="$STATE_ROOT/pr-dispatch/launches.tsv"
# あれば、再開と起動を全部止める (ボードの更新は続ける)。
BRAKE_FILE="$STATE_ROOT/pr-dispatch/BRAKE"
# agent-resume.sh の状態。指示を渡して再開したタブの記録 (resume-pending.tsv) と、セッションの印 (sessions/)。
RESUME_STATE_DIR="$STATE_ROOT/agent-resume"
PENDING_FILE="$RESUME_STATE_DIR/resume-pending.tsv"
# 再開したセッションに指示が入らないまま、これだけ経ったらカードで知らせる (秒)。待ち自体は時間では解かない。
PENDING_NOTICE_AFTER="${PENDING_NOTICE_AFTER:-3600}"
# 起動の結果が分からないまま、これだけ経ったら人に上げる (秒)。
LAUNCH_UNKNOWN_AFTER="${LAUNCH_UNKNOWN_AFTER:-1800}"
# 追跡しない設定 (key=value を 1 行ずつ)。無ければ worktree は作らず、今までどおりの PR 対応だけをする。
#   adopt_prs=true      worktree の無い PR に worktree を作る
#   max_worktrees=<数>  Orca の worktree (主 checkout 以外) がこの数に達していたら作らない。無ければ作らない
#   queue_repos=<owner/repo,...> queue_label=<ラベル>  キューの対象。どちらかが空ならキューは無効
#   max_wip / max_per_day / max_open_prs  キューの新しい着手を止める線 (下の「キュー」の節)
#   ask_labels=<ラベル,...> ask_title_words=<語,...>  当たる issue はキューに入っていても起動しない
#   verify_skill=<skill 名> verify_probe=<コマンド>  無人の実機検証。このスクリプトは読まず、worker が読む (issue-worker の skill)
CONFIG_FILE="$STATE_ROOT/pr-dispatch/config"
# worktree を作った記録 (追記のみ)。<時刻> <creating|created|ready|fail|refused> <PR> <head の SHA> [<worktree>]
# creating は作る前と、worktree が出来た直後 (path 付き) の 2 回書く。created は PR の branch への切り替えまで済んだ、
# ready は setup が終わった (か、setup の無いリポ)。path 付きの行が creating で止まっている worktree には起動しない。
ADOPTS_FILE="$STATE_ROOT/pr-dispatch/adopts.tsv"
# これより古い PR には worktree を作らない (日)。放置された PR のために環境を立ち上げない。
# Dependabot が 30 日動きの無い PR の rebase をやめるのを参考にした、独自の線。
ADOPT_MAX_AGE_DAYS="${ADOPT_MAX_AGE_DAYS:-30}"
# 作った worktree の setup が終わるのを待つ上限 (秒)。過ぎたら人に上げる。
ADOPT_SETUP_WAIT="${ADOPT_SETUP_WAIT:-1200}"
# キュー由来の worker が working のまま、これだけ更新が無ければ「停止の疑い」を付ける (秒)。
QUEUE_STALL_AFTER="${QUEUE_STALL_AFTER:-7200}"
# 題名にこの語が入る issue は、キューに入っていても起動しない (人が判断する領域)。ask_title_words で置き換える。
DEFAULT_TITLE_WORDS="security —,infra —,本番,prd,prod,個人情報,PII,Secret"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
# 数分ごとに同じ内容が並ぶ見送りの理由は、VERBOSE=1 のときだけ出す。
vlog() { [ "$VERBOSE" = "1" ] && log "$@"; return 0; }

# orca_set <orca worktree set の引数...>: カードを書き換える。書けたら 0。
# 列を作り直して内部名が変わると、exit 0 でも warnings が返って列は動かないので、warnings があれば書けていない扱いにする。
orca_set() {
    local out
    out=$(orca worktree set "$@" 2>/dev/null) &&
        jq -e '[.. | objects | .warnings? // empty | .[]?] | length == 0' <<<"$out" >/dev/null 2>&1
}

# cfg <key> <default>: 設定の値。ファイルはシェルとして読まない (書かれた値を実行しない)。
cfg() {
    local v
    v=$(sed -n "s/^$1=//p" "$CONFIG_FILE" 2>/dev/null | tail -n 1)
    printf '%s' "${v:-$2}"
}
adopt_on=0
[ "$(cfg adopt_prs false)" = "true" ] && adopt_on=1
# キュー: 対象のリポ (改行区切り) とラベル。ラベル名と対象は追跡しない設定にだけ書く。
queue_label=$(cfg queue_label "")
queue_repos=$(cfg queue_repos "" | tr ', ' '\n\n' | awk 'NF')
queue_on=0
[ -n "$queue_label" ] && [ -n "$queue_repos" ] && queue_on=1

# ---- キューの issue の読み方 (ループと check で同じものを使う) ----
# 内側の一覧は pageInfo を取り、欠けていれば対象外にする (読めていない部分に、止める理由があるかもしれない)。
QUEUE_FRAGMENT='
fragment Q on Issue {
  number title state createdAt lastEditedAt
  author { login }
  editor { login }
  repository { nameWithOwner defaultBranchRef { name } }
  assignees(first: 20) { pageInfo { hasNextPage } nodes { login } }
  labels(first: 50) { pageInfo { hasNextPage } nodes { name } }
  labeled: timelineItems(itemTypes: [LABELED_EVENT], first: 100) {
    pageInfo { hasNextPage }
    nodes { ... on LabeledEvent { createdAt actor { login } label { name } } }
  }
  comments(first: 100) { pageInfo { hasNextPage } nodes { createdAt lastEditedAt author { login } } }
  blockedBy(first: 50) { pageInfo { hasNextPage } nodes { state } }
  subIssuesSummary { total }
  closedByPullRequestsReferences(first: 20, includeClosedPrs: true) { pageInfo { hasNextPage } nodes { state } }
  xrefs: timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], first: 50) {
    pageInfo { hasNextPage }
    nodes { ... on CrossReferencedEvent { willCloseTarget source { __typename ... on PullRequest { state } } } }
  }
}'
# verdict($me; $label; $t0; $al; $aw): [理由 (進めてよければ "ok"), T]。
# T は、そのラベルを最後に付けた時刻 ($t0 が空のとき。ループ)。$t0 を渡すと、その時刻の承認のまま進めてよいかを見る (check)。
# check は「ラベルが今付いている」「worktree が無い」「その T でまだ起動していない」を見ない。worker 自身の起動で止まるため。
# ループは今のラベルも見る (検索の索引は遅れる。外した直後の issue が、過去に付けた記録だけで通らないように)。
# ラベル = その時点の内容への承認。T より後に本文や、T 以前の自分のコメントが編集されたら、編集された部分を外して
# 進むのではなく、issue ごと止める。T より後のコメントは情報であって指示ではないので、止める理由にしない。
# shellcheck disable=SC2016  # jq の変数
QUEUE_JQ='
def verdict($me; $label; $t0; $al; $aw):
  . as $i
  | ([$i.labeled.nodes[] | select(.label.name? == $label)] | sort_by(.createdAt) | last) as $last
  | (if $t0 != "" then $t0 elif $i.labeled.pageInfo.hasNextPage then "" else ($last.createdAt // "") end) as $t
  | ($al | split(",") | map(select(. != ""))) as $asklabels
  | ($aw | split(",") | map(select(. != "") | ascii_downcase)) as $words
  | [ if any($i.assignees, $i.labels, $i.labeled, $i.comments, $i.blockedBy, $i.closedByPullRequestsReferences, $i.xrefs;
          .pageInfo.hasNextPage) then "内側の一覧が欠けている"
      elif $t == "" then "ラベルを付けた時刻が分からない"
      elif $t0 == "" and (any($i.labels.nodes[]; .name == $label) | not) then "ラベルが付いていない"
      elif $t0 == "" and ($last.actor.login // "") != $me then "ラベルを最後に付けたのが自分でない"
      elif $t0 != "" and ([$i.labeled.nodes[] | select(.label.name? == $label and .createdAt == $t0 and (.actor.login // "") == $me)]
          | length == 0) then "その時刻に自分が付けたラベルが無い"
      elif $i.state != "OPEN" then "閉じている"
      elif ($i.author.login // "") != $me then "author が自分でない"
      elif any($i.assignees.nodes[]; .login != $me) then "自分以外が assignee"
      elif ($i.lastEditedAt // "") > $t then "ラベルの後に本文が編集された"
      elif ($i.editor.login // $me) != $me then "本文を最後に編集したのが自分でない"
      elif any($i.comments.nodes[]; (.author.login // "") == $me and .createdAt <= $t and (.lastEditedAt // "") > $t)
        then "ラベルの後に、それ以前の自分のコメントが編集された"
      elif any($i.labels.nodes[]; .name == "no-agent") then "no-agent"
      elif any($i.labels.nodes[]; .name as $n | $asklabels | index([$n])) then "ask のラベル"
      elif (($i.title // "") | ascii_downcase) as $ti | any($words[]; . as $w | $ti | contains($w)) then "ask の語"
      elif any($i.blockedBy.nodes[]; .state == "OPEN") then "開いている blocker がある"
      elif ($i.subIssuesSummary.total // 0) > 0 then "子 issue がある"
      elif any($i.closedByPullRequestsReferences.nodes[]; .state == "OPEN" or .state == "MERGED")
          or any($i.xrefs.nodes[]; .willCloseTarget == true and .source.__typename == "PullRequest"
              and (.source.state == "OPEN" or .source.state == "MERGED")) then "閉じる PR がある"
      else "ok" end,
      $t ];'

# queue_issue <repo> <番号>: 1 件の issue を、キューの判定に使う形で取る。
queue_issue() {
    # shellcheck disable=SC2016  # GraphQL の変数
    gh api graphql -F n="$2" -f owner="${1%%/*}" -f name="${1#*/}" -f query='
query($owner: String!, $name: String!, $n: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) { issue(number: $n) { ...Q } }
}'"$QUEUE_FRAGMENT" 2>/dev/null
}
# check <N> <T>: worker が着手の直前に呼ぶ。リポは呼んだ場所 (worker の worktree) の origin から取る。
# ロックは取らず、状態も書かない (ループの最中でも呼べる)。
queue_check() {
    local n=$1 t=$2 slug json res
    case "$n" in '' | *[!0-9]*) n="" ;; esac
    if [ -z "$n" ] || [ -z "$t" ]; then
        echo "使い方: pr-dispatch.sh check <issue の番号> <T>"
        return 2
    fi
    [ -n "$queue_label" ] || { echo "確かめられない: config に queue_label が無い"; return 2; }
    slug=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') || slug=""
    [ -n "$slug" ] || { echo "確かめられない: ここの origin が GitHub のリポでない"; return 2; }
    json=$(queue_issue "$slug" "$n") || { echo "確かめられない: GitHub から issue を取れない"; return 2; }
    res=$(jq -r --arg label "$queue_label" --arg t "$t" --arg al "$(cfg ask_labels "")" --arg aw "$(cfg ask_title_words "$DEFAULT_TITLE_WORDS")" \
        "$QUEUE_JQ"' .data.viewer.login as $me | .data.repository.issue
        | if . == null then "issue が無い" else verdict($me; $label; $t; $al; $aw)[0] end' <<<"$json" 2>/dev/null) ||
        { echo "確かめられない: GitHub の返事を読めない"; return 2; }
    [ -n "$res" ] || { echo "確かめられない: GitHub の返事を読めない"; return 2; }
    echo "$res"
    [ "$res" = "ok" ]
}

flagged=0
# この回に Needs decision に上げた worktree (改行区切り)。カードの列は回の最初に読んだきりなので、同じ worktree に当たる
# 別の PR (同じ branch から base の違う PR) が、上げた直後に起動したりカードを In review に戻したりしないよう、
# この回の残りでも Needs decision として扱う。
raised=""
# board <path> <reason> <sig> <status|-> <comment>
# (path, reason, sig) を初めて見たときだけボードに書く。status が - なら列は動かさず未読とコメントだけ付ける。
# Done (completed) へ移すときは人の対応が要らないので、未読にしない。
board() {
    local wt=$1 reason=$2 sig=$3 status=$4 comment=$5 key
    key="$wt"$'\t'"$reason"$'\t'"$sig"
    grep -qxF -- "$key" "$BOARD_FILE" && return 0
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: board $reason → ${wt#"$ORCA_ROOT"/} ($status) $comment"
        flagged=$((flagged + 1))
        return 0
    fi
    local args=(--worktree "path:$wt" --comment "$comment" --json)
    [ "$status" = "completed" ] || args+=(--unread)
    [ "$status" = "-" ] || args+=(--workspace-status "$status")
    # 書けていないのに覚えると、その通知は二度と出ない。
    if orca_set "${args[@]}"; then
        printf '%s\n' "$key" >>"$BOARD_FILE"
        log "board $reason → ${wt#"$ORCA_ROOT"/}: $comment"
        flagged=$((flagged + 1))
        [ "$status" != "needs-decision" ] || raised="$raised$wt"$'\n'
    else
        log "WARN: ボードに書けない $reason → $wt (次回に再試行)"
    fi
}

# 最後の発言が質問で終わっているか (最終行が疑問符で終わる)。
# 人の判断待ちは AskUserQuestion で出させ、Claude には Stop hook (question-guard.sh) で強制している。
# これは hook の効かない Codex や古いセッション向けの保険。「ください」などの依頼の言い回しまで
# 拾うと、2026-10-26 の初回で 5 件中 4 件が誤判定だったので、疑問符だけに絞った。
looks_like_question() {
    printf '%s' "$1" | awk 'NF' | tail -n 1 | grep -Eq '[?？][[:space:]）)」』*]*$'
}

if [ "${1:-}" = "check" ]; then
    rc=0
    queue_check "${2:-}" "${3:-}" || rc=$?
    exit "$rc"
fi

# agent-resume.sh と同時には動かない。DRY_RUN は何も起動しないので、ロックを取らない
# (手で確かめている間に、本番の回を見送らせない)。
# shellcheck source=home/scripts/dispatch-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/dispatch-lock.sh"
if [ "$DRY_RUN" != "1" ]; then
    dispatch_lock || exit 0
fi

braked=0
if [ -e "$BRAKE_FILE" ]; then
    braked=1
    vlog "BRAKE がある。再開と起動は止め、ボードだけ更新する"
fi

if ! orca status --json 2>/dev/null | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1; then
    log "Orca のランタイムに届かない。見送り (次回に拾う)"
    exit 0
fi

# ---- 再開。観測より先に動かす ----
# ロックは持ったまま渡す (agent-resume.sh は自分では取らない)。失敗しても続ける。
# ロックが指すのは自分の pid だけなので、自分だけが落ちて子が残ると、次の回がロックを回収して子と並んで動く。
# launchd の下では起きない。ジョブが死ぬと、launchd が同じプロセスグループの残りを kill する
# (man launchd.plist の AbandonProcessGroup。2026-11-10 に実機で、親だけを kill -9 すると子も 2 秒以内に消えるのを確かめた)。
# ponytail: 端末から手で動かして親だけを kill したときは守られない。そういう使い方をするなら、子の pid もロックに持たせる
# 再開しそこねたセッションの worktree は、下の「前の起動の印」で飛ばす。
if [ "$braked" = 0 ]; then
    DISPATCH_LOCK_HELD=1 STATE_ROOT="$STATE_ROOT" bash "$(dirname "${BASH_SOURCE[0]}")/agent-resume.sh" ||
        log "WARN: agent-resume.sh が失敗した (PR の対応は続ける)"
fi

me=$(gh api user -q .login 2>/dev/null) || {
    log "WARN: GitHub に届かない。見送り"
    exit 0
}
mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$BOARD_FILE")" "$(dirname "$LAUNCHES_FILE")"
touch "$STATE_FILE" "$BOARD_FILE" "$LAUNCHES_FILE" "$ADOPTS_FILE"

# ---- Orca の worktree: "<owner/repo>\t<branch>\t<path>\t<board status>" ----
wt_json=$(orca worktree list --json 2>/dev/null) || {
    log "WARN: Orca の worktree の一覧を取れない。見送り"
    exit 0
}
worktrees=""
while IFS=$'\t' read -r wt_path branch legacy status; do
    slug=$(git -C "$wt_path" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') || continue
    [ -n "$slug" ] || continue
    # 移行: 以前の版は、マージ待ちのカードを Needs decision に置いていた (コメントが「マージ判断:」で始まる)。
    # In review に戻す。Needs decision のままだと、その PR に conflict が出ても自動の対応が止まる。
    # ponytail: Needs decision に「マージ判断:」のカードが無くなったら、この節と jq の legacy の列を消す
    if [ "$status" = "needs-decision" ] && [ "$legacy" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY-RUN: board マージ判断のカードを In review に戻す → ${wt_path#"$ORCA_ROOT"/}"
        elif orca_set --worktree "path:$wt_path" --workspace-status in-review --json; then
            log "board マージ判断のカードを In review に戻した → ${wt_path#"$ORCA_ROOT"/}"
            status=in-review
        else
            log "WARN: マージ判断のカードを In review に戻せない → $wt_path (次回に再試行)"
        fi
    fi
    worktrees="$worktrees$slug"$'\t'"$branch"$'\t'"$wt_path"$'\t'"$status"$'\n'
done < <(jq -r --arg root "$ORCA_ROOT" '
    .result.worktrees[]
    | select((.isMainWorktree | not) and (.path | startswith($root + "/")) and ((.branch // "") != ""))
    | [.path, (.branch | sub("^refs/heads/"; "")), (if (.comment // "") | startswith("マージ判断:") then "1" else "0" end),
       (.workspaceStatus // "")] | @tsv' <<<"$wt_json")

# Orca に登録したリポ: "<owner/repo>\t<主 checkout の path>\t<repoId>"。worktree を作るときだけ使う (作った worktree の扱いには使わない)。
mains=""
if [ "$adopt_on" = 1 ] || [ "$queue_on" = 1 ]; then
    while IFS=$'\t' read -r main_path main_rid; do
        slug=$(git -C "$main_path" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') || continue
        [ -n "$slug" ] || continue
        mains="$mains$slug"$'\t'"$main_path"$'\t'"$main_rid"$'\n'
    done < <(jq -r '.result.worktrees[] | select(.isMainWorktree) | [.path, (.repoId // "-")] | @tsv' <<<"$wt_json")
fi

if [ -z "$worktrees" ] && [ -z "$mains" ]; then
    log "Orca の worktree が無い。終了"
    exit 0
fi

# ---- PR の状態を 1 回の問い合わせで取る (検索は worktree のあるリポと、worktree を作るなら登録したリポに絞る) ----
repos=$(printf '%s%s' "$worktrees" "$mains" | cut -f1 | sort -u | sed 's/^/repo:/' | tr '\n' ' ')
search="is:pr is:open draft:false archived:false author:$me $repos"
# 100 件を超えても全部読む。--paginate は、$endCursor を受け取り pageInfo を返す query を、ページごとに打ち直す
# (https://cli.github.com/manual/gh_api)。出力はページごとの JSON が並ぶ。
# shellcheck disable=SC2016  # $q と $endCursor は GraphQL の変数。シェルに展開させない
prs_json=$(gh api graphql --paginate -f q="$search" -f query='
query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number
        url
        title
        createdAt
        isCrossRepository
        author { login }
        headRefName
        headRefOid
        mergeable
        mergeStateStatus
        autoMergeRequest { enabledAt }
        repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        reviewThreads(first: 100) {
          pageInfo { hasNextPage }
          nodes { isResolved comments(last: 1) { nodes { id author { login } } } }
        }
      }
    }
  }
}' 2>/dev/null) || {
    log "WARN: GitHub から PR を取れない。見送り"
    exit 0
}
# 未対応のレビュー = 未解決のスレッドのうち、最後の発言が自分以外のもの。その発言 ID の並びを状態に使う。
# 無いときは "-"。空欄にすると read がタブの連続を 1 つに詰め、後ろの列がずれる。
# スレッドが 100 を超えて全部は読めていないときは "?" (未対応が無いとは言えないので、その PR には何もしない)。
# 検索は author で絞っているが、返ってきた PR の author も確かめる (他人の PR に worktree を作ったり、エージェントを起動したりしない)。
prs=$(jq -r --arg me "$me" '.data.search.nodes[] | select(.author.login == $me)
    | [ .repository.nameWithOwner, .headRefName, (.number | tostring), .url, .headRefOid, .mergeable,
        (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"),
        (if .reviewThreads.pageInfo.hasNextPage then "?" else
          ([.reviewThreads.nodes[] | select((.isResolved | not) and (.comments.nodes[0].author.login != $me))
            | .comments.nodes[0].id] | sort | join(",") | if . == "" then "-" else . end) end),
        .mergeStateStatus, (if .autoMergeRequest then "auto" else "manual" end),
        (.createdAt // "")[0:10], (if .isCrossRepository then "1" else "0" end),
        ((.title // "-") | gsub("[\t\r\n]"; " ")) ] | @tsv' <<<"$prs_json") || {
    log "WARN: GitHub の返事を読めない。見送り"
    exit 0
}

# ---- Orca の観測: 端末 → エージェントの順に取る ----
# 端末の一覧は、再開待ちの記録があるときだけ要る。取れない・途中で切れているときは、この回は何も解除しない。
terms_json=""
if [ -s "$PENDING_FILE" ]; then
    terms_json=$(orca terminal list --json 2>/dev/null) || terms_json=""
    jq -e '(.result.terminals | type == "array") and (.result.truncated != true)' <<<"$terms_json" >/dev/null 2>&1 || terms_json=""
fi
# エージェントの状態が分からない回は、何も起動しない。
# 以前は取れないと {} で続け、動いているエージェントの居る worktree にも起動していた。
ps_json=$(orca worktree ps --json 2>/dev/null) || ps_json=""
if ! jq -e '(.result.worktrees | type == "array") and (.result.truncated != true)' <<<"$ps_json" >/dev/null 2>&1; then
    log "WARN: Orca のエージェントの状態を取れない (失敗か、一覧が途中で切れた)。見送り"
    exit 0
fi
wt_path_of() { jq -r --arg w "$1" '[.result.worktrees[] | select(.worktreeId == $w) | .path][0] // empty' <<<"$ps_json"; }

# ---- 再開待ち ----
# agent-resume.sh は、指示を渡して再開したタブを resume-pending.tsv に書く。そのタブに指示が入るまで
# (Orca がエージェントの prompt を返すまで)、同じ worktree には起動しない。
# 解除は、この回に取った観測だけで決める。state では決めない (数秒で終わる指示の working は、数分おきの観測では見逃す)。
# hold: この回は起動しない worktree の path。この回に解除した行の worktree も含める。
hold=""
if [ -s "$PENDING_FILE" ]; then
    keep=""
    now=$(date +%s)
    while IFS=$'\t' read -r handle pane wtid sid t; do
        [ -n "$wtid" ] || continue
        case "$t" in '' | *[!0-9]*) t=0 ;; esac # 時刻が読めない行は、古いものとして扱う (すぐ知らせる)
        path=$(wt_path_of "$wtid")
        [ -z "$path" ] || hold="$hold$path"$'\n'
        why=""
        if [ -n "$terms_json" ]; then
            if [ "$handle" = "-" ]; then
                # タブを作れたか分からない行。その worktree の端末が 1 つも無くなるまで待つ (タイトルは実行中に変わるので見ない)。
                jq -e --arg w "$wtid" '[.result.terminals[] | select(.worktreeId == $w)] | length == 0' <<<"$terms_json" >/dev/null && why="端末が無い"
            else
                jq -e --arg h "$handle" '[.result.terminals[] | select(.handle == $h)] | length == 0' <<<"$terms_json" >/dev/null && why="タブが閉じた"
            fi
        fi
        if [ -z "$why" ] && [ "$handle" != "-" ] && [ "$pane" != "-" ] &&
            jq -e --arg p "$pane" '[.result.worktrees[].agents[]? | select(.paneKey == $p and ((.prompt // "") != ""))] | length > 0' <<<"$ps_json" >/dev/null; then
            why="指示が入った"
        fi
        if [ -n "$why" ]; then
            log "再開待ちを解除 $sid ($why)"
            continue
        fi
        keep="$keep$handle"$'\t'"$pane"$'\t'"$wtid"$'\t'"$sid"$'\t'"$t"$'\n'
        if [ -n "$path" ] && [ "$((now - t))" -ge "$PENDING_NOTICE_AFTER" ]; then
            board "$path" resume-pending "$sid:$t" - "再開したセッションが始まらない。タブを閉じると PR の自動対応が再開する"
        fi
    done <"$PENDING_FILE"
    if [ "$DRY_RUN" != "1" ]; then
        printf '%s' "$keep" >"$PENDING_FILE.tmp" && mv "$PENDING_FILE.tmp" "$PENDING_FILE"
    fi
fi
# 前の起動の印が残っている worktree も待つ。再開はこの回の最初に済ませているので、残るのは再開しそこねたとき。
boot=$(sysctl -n kern.bootsessionuuid 2>/dev/null || true)
for f in "$RESUME_STATE_DIR/sessions"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r b _ wtid _ <"$f" || continue
    [ "$b" = "$boot" ] && continue
    path=$(wt_path_of "$wtid")
    [ -z "$path" ] || hold="$hold$path"$'\n'
done

# ---- 起動の記録 ----
# launch_log <key> <状態> <operationId|-> [時刻]
launch_log() { printf '%s\t%s\t%s\t%s\n' "${4:-$(date +%s)}" "$2" "$3" "$1" >>"$LAUNCHES_FILE"; }
# launch_mark <時刻>: 起動ごとの印。指示の中に入れておき、起動できたかを Orca が返すエージェントの prompt で確かめる。
# 時刻は、その起動の最初の launching の行のもの (同じ worktree への起動は 1 回の実行に 1 つなので、重ならない)。
launch_mark() { printf 'pr-dispatch による自動起動 %s。' "$1"; }
# launch_last <key>: その (PR, 対応, 状態) の最後の行の "<時刻> <状態> <operationId>"。無ければ空。
launch_last() {
    awk -F'\t' -v k="$1" '$4 FS $5 FS $6 == k { l = $1 FS $2 FS $3 } END { if (l != "") print l }' "$LAUNCHES_FILE"
}
# launch_open <PR>: その PR の最後の起動が結果待ち (最後の行が launching か lost) なら
# "<最初に結果が分からなくなった時刻> <operationId|-> <対応> <状態>"。そうでなければ空。
# PR ごとに見る (状態ごとではない)。push やレビューで状態が変わっても、前の起動の結果が分かるまでは次を起動しないため。
# 出し直し (launching <id> → lost <id>) が続いても、時刻は最初のものを返す (出し直すたびに期限が延びないように)。
launch_open() {
    awk -F'\t' -v p="$1" '
        $4 == p {
            if (st != "launching" && st != "lost") t0 = $1
            st = $2; op = $3; a = $5; s = $6
        }
        END { if (st == "launching" || st == "lost") print t0 FS op FS a FS s }' "$LAUNCHES_FILE"
}
# launch_close <key> <launched|unknown>: 結果待ちの起動を閉じ、起動済みとして覚える (同じ状態には起動し直さない)。
launch_close() {
    [ "$DRY_RUN" = "1" ] && return 0
    launch_log "$1" "$2" - || true
    grep -qxF -- "$1" "$STATE_FILE" || printf '%s\n' "$1" >>"$STATE_FILE"
}
# launch_seen <worktree> <時刻>: その時刻の起動の印が入った指示を受け取ったエージェントが、その worktree に居る。
# 時刻の前後では確かめない (起動の後に人が始めた別のセッションまで、起動できた証拠に数えてしまう)。
launch_seen() {
    jq -e --arg p "$1" --arg m "$(launch_mark "$2")" \
        '[.result.worktrees[] | select(.path == $p) | .agents[]? | select((.prompt // "") | contains($m))] | length > 0' <<<"$ps_json" >/dev/null
}
# launch_agent <key> <worktree> <prompt> <operationId|-> <時刻> [orca agent launch に足す引数...]: エージェントを起動する。起動できたら 0。
# 起動の前に launching、結果が分かったら launched / lost / fail を書く。どれも書かれなければ結果不明。
# 時刻は、新しい起動の launching の行に書く時刻 (prompt の印と同じ値にする)。出し直しの行は今の時刻で書く。
launch_agent() {
    local key=$1 wt=$2 prompt=$3 op=$4 t=$5 out rc=0 newop
    [ "$op" = "-" ] || t=""
    local args=(agent launch --agent claude --worktree "path:$wt" --prompt "$prompt" --json)
    [ $# -le 5 ] || args+=("${@:6}")
    # 返事を失った起動は、新しく起動し直さず、同じ依頼を出し直す (orca agent launch --help の --retry-launch)。
    [ "$op" = "-" ] || args+=(--retry-launch "$op")
    launch_log "$key" launching "$op" "$t" || {
        log "WARN: 起動の記録を書けない。起動しない"
        return 1
    }
    # --retry-launch は同じディレクトリからの再送を求めるので、呼び出し元の cwd によらず固定する。
    out=$(cd "$HOME" && orca "${args[@]}" 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ] && jq -e '.ok == true' <<<"$out" >/dev/null 2>&1; then
        launch_log "$key" launched - || true
        return 0
    fi
    newop=$(jq -r '[.. | .operationId? // empty | strings][0] // empty' <<<"$out" 2>/dev/null || true)
    if [ -n "$newop" ]; then
        launch_log "$key" lost "$newop" || true
    elif [ "$op" != "-" ]; then
        # 出し直しが通らなくても、最初の依頼が通っていないとは言えない。operationId を持ったまま結果待ちに残す
        # (fail にすると、次の回に新しい起動として出し、最初の依頼が通っていたら 2 体並ぶ)。
        launch_log "$key" lost "$op" || true
    elif jq -e '.ok == false and ((.error.code // "") | test("^agent_session_operation_(unknown|expired)$") | not)' <<<"$out" >/dev/null 2>&1; then
        # はっきり失敗と分かるものだけ fail にする。上の 2 つのコードは、Orca の CLI 自身が「結果不明」に分類している。
        launch_log "$key" fail - || true
    fi
    return 1
}

# ---- worktree を作った記録 (作るのは下の「worktree の無い PR」の節) ----
adopt_log() { printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$2" "$1" "$3" "${4:-}" >>"$ADOPTS_FILE"; } # adopt_log <PR> <状態> <SHA> [worktree]
# adopt_last <PR>: その PR の最後の行の "<状態> <SHA> <時刻>"。無ければ空。
adopt_last() { awk -F'\t' -v p="$1" '$3 == p { l = $2 FS $4 FS $1 } END { if (l != "") print l }' "$ADOPTS_FILE"; }
# adopt_wt_last <worktree>: その worktree の最後の行の "<状態> <PR> <時刻>"。自分で作った worktree でなければ空。
adopt_wt_last() { awk -F'\t' -v w="$1" '$5 == w { l = $2 FS $3 FS $1 } END { if (l != "") print l }' "$ADOPTS_FILE"; }
# setup_done <worktree>: その worktree の端末のどれかに、setup script が最後に出す行が出ている。
# 途中の生成物の有無では判定しない (issue-worker skill の setup 待ちと同じ印)。
setup_done() {
    local h
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        orca terminal read --terminal "$h" --limit 200 --json 2>/dev/null |
            jq -e '[.result.terminal.tail[]? | select(test("Orca setup done:"))] | length > 0' >/dev/null 2>&1 && return 0
    done < <(orca terminal list --worktree "path:$1" --json 2>/dev/null | jq -r --arg p "$1" '.result.terminals[]? | select((.worktreePath // $p) == $p) | .handle')
    return 1
}
# adopt_ready <worktree>: この worktree に起動してよいか。自分で作った worktree は、setup が終わるまで待つ
# (環境を作っている最中にエージェントを動かすと、依存の導入などが重なる)。作っていない worktree は、いつでも 0。
# 記録は PR ではなく worktree で引く。同じ branch から base の違う PR を出していると、どの PR もこの worktree に当たる。
adopt_ready() {
    local st="" apr="" t="" rid
    IFS=$'\t' read -r st apr t <<<"$(adopt_wt_last "$1")" || true
    [ "$st" = "creating" ] || return 0
    [ "$DRY_RUN" != "1" ] || return 1
    # setup script の無いリポは、待つものが無い。無いと判断するのは、Orca の返事を読めて local の script が空で、
    # checkout の orca.yaml にも setup が無いときだけ (取れなかったときに「無い」と見なすと、setup の最中に起動してしまう)。
    # Orca は local に script が無ければ checkout の orca.yaml の setup を走らせる。repo show に出るのは local の分だけ。
    # リポは worktree の一覧から引く (worktree を作る設定を消したあとも、作った worktree の判定は続ける)。
    rid=$(jq -r --arg p "$1" '[.result.worktrees[] | select(.path == $p) | .repoId // empty][0] // empty' <<<"$wt_json")
    if { [ ! -e "$1/orca.yaml" ] || [ "$(grep -Ec "setup[\"']?[[:space:]]*:" "$1/orca.yaml" 2>/dev/null)" = 0 ]; } &&
        orca repo show --repo "id:$rid" --json 2>/dev/null |
        jq -e '(.result.repo | type == "object") and ((.result.repo.hookSettings.scripts.setup // "") == "")' >/dev/null 2>&1; then
        adopt_log "$apr" ready - "$1" || true
        return 0
    fi
    if setup_done "$1"; then
        adopt_log "$apr" ready - "$1" || true
        return 0
    fi
    if [ "$(($(date +%s) - t))" -ge "$ADOPT_SETUP_WAIT" ]; then
        # setup が終わった印が出ない (失敗したか、印を出さない script)。人に上げ、カードが Needs decision から戻されたら起動する。
        board "$1" adopt-setup "$t" needs-decision "PR #${apr#*#}: worktree の setup が終わったか確認できない（終わっていたら、カードを In review に戻す）"
        ! grep -qxF -- "$1"$'\t'"adopt-setup"$'\t'"$t" "$BOARD_FILE" || adopt_log "$apr" ready - "$1" || true
    fi
    return 1
}

launched=0
# この回に PR 対応を起動した worktree (改行区切り)。エージェントの状態は回の最初に読んだきりなので、キューの枠の数え方で使う。
started=""
while IFS=$'\t' read -r slug branch num url head mergeable ci threads merge_state merge_mode _; do
    [ -n "$slug" ] || continue
    line=$(printf '%s' "$worktrees" | awk -F'\t' -v s="$slug" -v b="$branch" '$1 == s && $2 == b { print; exit }')
    [ -n "$line" ] || continue
    wt=$(printf '%s' "$line" | cut -f3)
    board=$(printf '%s' "$line" | cut -f4)
    # この回に Needs decision に上げた worktree は、読んだ列が古い。起動にも「マージ可」にも、Needs decision として扱う。
    ! printf '%s' "$raised" | grep -qxF -- "$wt" || board=needs-decision
    pr="$slug#$num"

    if [ "$mergeable" = "CONFLICTING" ]; then
        action="sync-pr"; sig="$head"
    elif [ "$ci" = "FAILURE" ] || [ "$ci" = "ERROR" ]; then
        action="fix-ci"; sig="$head"
    elif [ "$threads" = "?" ]; then
        vlog "keep  $pr (レビューのスレッドが 100 を超えて全部は読めない。何もしない)"
        continue
    elif [ "$threads" != "-" ]; then
        action="review-pr-comments"; sig="$head:$threads"
    else
        # 対応が要らない PR。CLEAN で auto-merge が無ければ、マージするかは人が決める。カードは In review に置き、
        # 未読と「マージ可」で知らせる。Needs decision には置かない (人が質問に答えるための列で、置くと、その PR に
        # あとから conflict が出ても自動の対応が止まる)。別の理由で Needs decision にあるカードは動かさない。
        if [ "$merge_state" = "CLEAN" ] && [ "$merge_mode" = "manual" ] && [ "$board" != "needs-decision" ]; then
            board "$wt" merge "$head" in-review "マージ可: #${num}"
        fi
        continue
    fi

    [ "$braked" = 0 ] || continue
    if [ "$board" = "needs-decision" ]; then
        vlog "keep  $pr ($action 候補だが Needs decision でユーザーの判断待ち)"
        continue
    fi
    if printf '%s' "$hold" | grep -qxF -- "$wt"; then
        vlog "keep  $pr ($action 候補だが、再開したセッションに指示が入るのを待っている)"
        continue
    fi
    if ! adopt_ready "$wt"; then
        vlog "keep  $pr ($action 候補だが、作ったばかりの worktree の setup が終わるのを待っている)"
        continue
    fi
    key="$pr"$'\t'"$action"$'\t'"$sig"

    # この PR の前の起動の結果が分かっていなければ、それを先に片付ける。push やレビューで状態が変わっていても、
    # 結果が分かるまで別の起動はしない (起動できていたら 2 体並ぶ)。
    o_time="" o_op="" o_action="" o_sig=""
    IFS=$'\t' read -r o_time o_op o_action o_sig <<<"$(launch_open "$pr")" || true
    op=- t0=""
    if [ -n "$o_time" ]; then
        o_key="$pr"$'\t'"$o_action"$'\t'"$o_sig"
        if launch_seen "$wt" "$o_time"; then
            # この起動の印が入った指示を受け取ったエージェントが居る。起動できていた。
            launch_close "$o_key" launched
            log "launch $o_action → $pr (返事は読めなかったが、この起動のエージェントを確認)"
            continue
        fi
        if [ "$(($(date +%s) - o_time))" -ge "$LAUNCH_UNKNOWN_AFTER" ]; then
            # 待っても、この起動のエージェントが現れない。これ以上は待たず、出し直しもせず、起動したものとして閉じる
            # (同じ状態には二度と起動しない)。状態が変わっていなければ PR は直らないまま残るので、人に上げてから閉じる。
            # 状態が変わっていれば、閉じたあと新しい起動として下へ進む。
            if [ "$o_key" = "$key" ]; then
                board "$wt" "launch-unknown-$o_action" "$o_sig" needs-decision "自動の /$o_action を起動できたか分からない: #$num"
                grep -qxF -- "$wt"$'\t'"launch-unknown-$o_action"$'\t'"$o_sig" "$BOARD_FILE" || continue
            fi
            launch_close "$o_key" unknown
            [ "$o_key" != "$key" ] || continue
        elif [ "$o_op" = "-" ]; then
            vlog "keep  $pr ($o_action: 前の起動の結果が分からない。起動し直さずに待つ)"
            continue
        else
            # 返事を失った起動。今の状態ではなく、失った依頼そのものを同じ operationId で出し直す。
            action=$o_action sig=$o_sig key=$o_key op=$o_op t0=$o_time
        fi
    fi

    busy=$(jq -r --arg p "$wt" '[.result.worktrees[] | select(.path == $p) | .agents[]?.state | select(. != "done")] | join(",")' <<<"$ps_json")
    if [ -n "$busy" ]; then
        vlog "keep  $pr ($action 候補だがエージェントが $busy)"
        continue
    fi
    # 回数の上限を、起動済みの状態かどうかより先に見る。後に見ると、最後の起動が何も push せずに終わったとき
    # (状態が変わらない) に、起動済みとして飛ばし続け、人に上がらない。
    attempts=$(grep -cF -- "$pr"$'\t'"$action"$'\t' "$STATE_FILE" || true)
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
        board "$wt" "give-up-$action" "$sig" needs-decision "自動の /$action を $attempts 回起動しても直らない: #$num"
        continue
    fi
    if grep -qxF -- "$key" "$STATE_FILE"; then
        continue
    fi
    fails=$(awk -F'\t' -v k="$key" '$2 == "fail" && $4 FS $5 FS $6 == k' "$LAUNCHES_FILE" | wc -l | tr -d ' ')
    if [ "$fails" -ge "$MAX_ATTEMPTS" ]; then
        board "$wt" "launch-fail-$action" "$sig" needs-decision "自動の /$action の起動に $fails 回失敗: #$num"
        continue
    fi
    # 人の作業を踏まない。エージェントが居なくても、未コミットの変更がある worktree には起動しない
    # (状態を読めないときも起動しない)。
    # --no-optional-locks: status は既定で index を書き直し、その間のロックが、同じ worktree で動いている git を失敗させうる
    # (git-status(1) の BACKGROUND REFRESH)。数分おきに打つので、ロックを取らない。
    if ! dirty=$(git -C "$wt" --no-optional-locks status --porcelain 2>/dev/null) || [ -n "$dirty" ]; then
        board "$wt" "dirty-$action" "$sig" - "未コミットの変更があるので、自動の /$action を見送り: #$num"
        continue
    fi
    if [ "$launched" -ge "$MAX_LAUNCHES" ]; then
        vlog "keep  $pr ($action: 今回の起動上限 $MAX_LAUNCHES に達した。次回)"
        continue
    fi

    # 出し直しは、失った依頼と同じ指示にする (印の時刻も最初のもの)。新しい起動の印は今の時刻。
    t0=${t0:-$(date +%s)}
    prompt="/$action $url

($(launch_mark "$t0")人は見ていない。判断が要るものはグローバル CLAUDE.md の「委任の線引き」どおり Needs decision に上げて止まる)"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: launch $action → $pr ($wt)"
        launched=$((launched + 1))
        started="$started$wt"$'\n'
        continue
    fi
    if launch_agent "$key" "$wt" "$prompt" "$op" "$t0"; then
        printf '%s\n' "$key" >>"$STATE_FILE"
        orca worktree set --worktree "path:$wt" --comment "auto: $action (#$num)" --json >/dev/null 2>&1 || true
        log "launch $action → $pr"
        launched=$((launched + 1))
        started="$started$wt"$'\n'
    else
        log "WARN: 起動できなかった $action → $pr ($(launch_last "$key" | cut -f2)。失敗なら次回に試し直し、返事を失ったなら同じ依頼を出し直す。分からなければ起動し直さない)"
    fi
done <<<"$prs"

# ---- worktree の無い PR に worktree を作る (adopt_prs=true のとき) ----
# 対応が要る (conflict・CI 失敗・未対応のレビュー) のに worktree が無い PR は、今までは人が手で対応していた。
# worktree を作っておけば、次の回から上の PR 対応がそのまま効く (起動はこの回にはしない)。1 回に 1 つ。
# adopt_pr <PR> <番号> <branch> <SHA> <主 checkout> <カードの名前>
# 返り値: 0 = 作った、2 = 手を付けずに見送った (次の候補を見てよい)、1 = 失敗した・途中で止まった。
adopt_pr() {
    local pr=$1 num=$2 branch=$3 oid=$4 main=$5 name=$6 out rc=0 wt tmp err fetched
    # ① ローカルの同名ブランチを PR の head まで進める (無ければ作る)。ローカルが先行・分岐していると git が拒否する。
    #    拒否されたら何もしない (未 push のコミットを捨てたり、勝手に push したりしない)。
    if ! err=$(git -C "$main" fetch origin "$branch:$branch" 2>&1); then
        if printf '%s' "$err" | grep -Eq 'rejected|refusing'; then
            log "adopt 見送り $pr: ローカルの $branch を PR の head に進められない ($(printf '%s' "$err" | grep -E 'rejected|refusing' | head -n 1 | sed 's/^[[:space:]]*//'))"
            adopt_log "$pr" refused "$oid" || true # head が変わるまで試し直さない
        else
            log "WARN: adopt $pr: fetch に失敗 (次回に再試行)"
        fi
        return 2
    fi
    fetched=$(git -C "$main" rev-parse --verify --quiet "refs/heads/$branch") || return 2
    adopt_log "$pr" creating "$oid" || {
        log "WARN: worktree を作る記録を書けない。作らない"
        return 1
    }
    # ② --pr だけでは PR の head を checkout しない (base から新しいブランチを切る)。head を base にして作り、③で切り替える。
    #    --no-parent: 実行した場所の Orca の親子関係を引き継がせない。cwd は固定する (pr-dispatch の起動と同じ)。
    out=$(cd "$HOME" && orca worktree create --repo "path:$main" --name "pr-$num" --branch "pr-$num" --pr "$num" \
        --base-branch "origin/$branch" --setup run --no-parent --json 2>/dev/null) || rc=$?
    wt=$(jq -r '.result.worktree.path // empty' <<<"$out" 2>/dev/null || true)
    if [ "$rc" != 0 ] || [ -z "$wt" ]; then
        # はっきり失敗と分かるときだけ fail (次の回に試し直す)。返事が読めないときは creating のまま残し、作り直さない。
        [ "$(jq -r '.ok' <<<"$out" 2>/dev/null || true)" != "false" ] || adopt_log "$pr" fail "$oid" || true
        log "WARN: adopt $pr: worktree を作れなかった ($(adopt_last "$pr" | cut -f1))"
        return 1
    fi
    # setup 待ち (adopt_ready) は worktree ごとに見るので、出来た worktree の path を付けてもう 1 行書く。
    adopt_log "$pr" creating "$oid" "$wt" || log "WARN: adopt $pr: setup 待ちの記録を書けない ($wt)"
    tmp=$(jq -r '.result.worktree.branch // empty' <<<"$out" 2>/dev/null | sed 's#^refs/heads/##')
    # ③ PR の branch に切り替える。①で揃えてあるので同じコミットの間の切り替えで、setup の最中でもファイルは変わらない。
    if ! git -C "$wt" switch -q "$branch" 2>/dev/null || [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$fetched" ]; then
        log "WARN: adopt $pr: PR の branch に切り替えられない。ここで止める ($wt)"
        board "$wt" adopt-stuck "$oid" needs-decision "PR #$num の取り込みが途中で止まった（branch が $branch になっていない）"
        return 1
    fi
    # Orca が作った仮のブランチを消す。名前は作成の返事から取る (使用済みの名前には Orca が数字を足すので、
    # 決め打ちの pr-<番号> を消すと別のブランチを消しうる)。-d はマージされていないブランチを消さない。
    [ -z "$tmp" ] || [ "$tmp" = "$branch" ] || git -C "$wt" branch -d "$tmp" >/dev/null 2>&1 || true
    # ①が branch を新しく作ったときは upstream が無く、push.default=simple では skill の push が失敗する。
    git -C "$wt" branch -q --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1 ||
        log "WARN: adopt $pr: upstream を設定できない ($wt)"
    # branch を切り替えると Orca の PR との結び付きが外れるので、付け直す。カードは PR のある作業の列 (In review) に置く。
    orca_set --worktree "path:$wt" --pr "$num" --workspace-status in-review --display-name "$name" \
        --comment "auto: PR #$num の対応のために worktree を作成" --json ||
        log "WARN: adopt $pr: カードを書けない ($wt)"
    adopt_log "$pr" created "$oid" || true # 起動は、setup が終わってから (adopt_ready)
    log "adopt $pr → ${wt#"$ORCA_ROOT"/}"
    return 0
}

# cfg_num <key> <default>: 数の設定。数でなければ default。
cfg_num() {
    local v
    v=$(cfg "$1" "$2")
    case "$v" in '' | *[!0-9]*) v=$2 ;; esac
    printf '%s' "$v"
}
# worktree の数の線は、worktree の無い PR の取り込みとキューの両方に効く (作った瞬間に数に入る)。
max_wt=$(cfg_num max_worktrees 0)
n_wt=$(jq '[.result.worktrees[] | select(.isMainWorktree | not)] | length' <<<"$wt_json")

if [ "$adopt_on" = 1 ] && [ "$braked" = 0 ]; then
    # macOS の date は -v、テストを回す CI (Linux) の date は -d。
    cutoff=$(date -v-"${ADOPT_MAX_AGE_DAYS}"d +%Y-%m-%d 2>/dev/null || date -d "$ADOPT_MAX_AGE_DAYS days ago" +%Y-%m-%d)
    while IFS=$'\t' read -r slug branch num url head mergeable ci threads merge_state merge_mode created cross title; do
        [ -n "$slug" ] || continue
        # 対応が要る PR だけ (上の PR 対応と同じ条件)。
        [ "$mergeable" = "CONFLICTING" ] || [ "$ci" = "FAILURE" ] || [ "$ci" = "ERROR" ] ||
            { [ "$threads" != "-" ] && [ "$threads" != "?" ]; } || continue
        [ -z "$(printf '%s' "$worktrees" | awk -F'\t' -v s="$slug" -v b="$branch" '$1 == s && $2 == b { print; exit }')" ] || continue
        pr="$slug#$num"
        main=$(printf '%s' "$mains" | awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }')
        [ -n "$main" ] || continue
        if [ "$cross" != "0" ]; then
            vlog "adopt 見送り $pr (fork からの PR)"
            continue
        fi
        if [ "$created" \< "$cutoff" ]; then
            vlog "adopt 見送り $pr (作成から $ADOPT_MAX_AGE_DAYS 日を超えている)"
            continue
        fi
        last="" last_oid=""
        IFS=$'\t' read -r last last_oid _ <<<"$(adopt_last "$pr")" || true
        # この PR が主な結び付き (linkedPR) になっている worktree が、別の branch で既にある。
        # 参照 (linkedItems) では見ない。1 つの worktree から branch を切り替えて PR を何本も出すと、前の PR の参照が
        # 全部その worktree に残る (実機で、1 つの worktree に 28 本)。それを「結び付いている」と数えると、
        # worktree を失った PR、つまりここで作りたい PR を、ほぼ全部見送ってしまう。
        linked=$(jq -r --arg m "$main" --argjson n "$num" '
            ([.result.worktrees[] | select(.isMainWorktree and .path == $m) | .repoId][0]) as $r
            | [.result.worktrees[] | select((.isMainWorktree | not) and .repoId == $r and .linkedPR == $n) | .path][0] // empty' <<<"$wt_json")
        if [ -n "$linked" ]; then
            if [ "$last" = "creating" ] || [ "$last" = "fail" ]; then
                # 前の回が、worktree を作ってから branch を切り替えるまでの間で止まった。自動では続けない。
                # fail も同じに扱う。Orca は応答待ちの時間切れや切断でも失敗を返すので、失敗と記録した作成で
                # worktree が出来ていることがある。エラーの種類では分けず、出来ているかどうかを見て決める。
                board "$linked" adopt-stuck "$last_oid" needs-decision "PR #$num の取り込みが途中で止まった（branch が $branch になっていない）"
            else
                vlog "adopt 見送り $pr (この PR に結び付いた worktree が別の branch で既にある: $linked)"
            fi
            continue
        fi
        case "$last" in
        created | ready) continue ;; # 一度作った PR。その worktree を人が消したのなら、作り直さない
        creating)
            vlog "adopt 見送り $pr (前の作成の結果が分からない。作り直さない)"
            continue
            ;;
        refused) [ "$last_oid" != "$head" ] || continue ;;
        esac
        fails=$(awk -F'\t' -v p="$pr" -v o="$head" '$3 == p && $4 == o && $2 == "fail"' "$ADOPTS_FILE" | wc -l | tr -d ' ')
        [ "$fails" -lt "$MAX_ATTEMPTS" ] || continue
        if [ "$n_wt" -ge "$max_wt" ]; then
            vlog "adopt 見送り $pr (worktree が $n_wt 個で、max_worktrees=$max_wt に達している)"
            break
        fi
        # 別の checkout で使用中の branch は git が fetch を拒否する。ネットワークを使う前に分かるので、先に見る。
        if git -C "$main" worktree list --porcelain 2>/dev/null | grep -qxF -- "branch refs/heads/$branch"; then
            vlog "adopt 見送り $pr ($branch は Orca の外の checkout で使用中)"
            continue
        fi
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY-RUN: adopt $pr (worktree を作る)"
            break
        fi
        rc=0
        adopt_pr "$pr" "$num" "$branch" "$head" "$main" "$(printf '%s: %s' "${slug#*/}" "$title" | cut -c1-60)" || rc=$?
        [ "$rc" != 2 ] || continue
        # 作成を試みた (結果が分からないときも)。worktree の一覧は回の最初に読んだきりなので、同じ回のキューの線に数える。
        n_wt=$((n_wt + 1))
        break
    done <<<"$prs"
fi

# ---- キュー: 自分がラベルを付けた自分の issue に、worktree を作って worker (/issue-worker) を起動する ----
# ラベル = その時点 (T) の内容への承認。起動できたらラベルを外す (付いている = まだ起動していない、が GitHub で見える)。
# 失敗した・PR を閉じた・worktree を消した issue は、勝手にやり直さない。やり直させる合図はラベルの付け直し (T が変わる)。
# 記録は launches.tsv に PR の起動と同じ形で書く (キーは "<repo>#<N> issue-worker <T>")。作成の前後も
# creating / fail の行で書く。副作用の前に 1 行、結果が分かったら 1 行。結果の分からない副作用は、自動ではやり直さない。

# キュー由来の worktree: branch が issue-<N>- で始まり、Orca の linkedIssue が N のもの (ps の形で読む)。
# "<repo>\t<path>\t<branch>\t<N>\t<列|->\t<動いているエージェントの state,...|->\t<エージェントの数>
#  \t<working のエージェントの最終更新 (ミリ秒)>\t<最新のエージェントの stateStartedAt>"
qwts=""
while IFS= read -r l; do
    [ -n "$l" ] || continue
    s=$(printf '%s' "$worktrees" | awk -F'\t' -v p="${l%%$'\t'*}" '$3 == p { print $1; exit }')
    qwts="$qwts${s:--}"$'\t'"$l"$'\n'
done < <(jq -r --arg root "$ORCA_ROOT" '
    .result.worktrees[]
    | select((.isMainWorktree | not) and (.path | startswith($root + "/")))
    | ((.branch // "") | sub("^refs/heads/"; "")) as $b
    | (($b | capture("^issue-(?<n>[0-9]+)-")?) // null) as $m
    | select($m != null and (((.linkedIssue // null) | if type == "object" then .number else . end | tostring) == $m.n))
    | (.agents // []) as $a
    | [.path, $b, $m.n, ((.workspaceStatus // "") | if . == "" then "-" else . end),
       ([$a[].state | select(. != "done")] | join(",") | if . == "" then "-" else . end),
       ($a | length | tostring),
       ([$a[] | select(.state == "working") | .updatedAt // 0] | max // 0 | tostring),
       (($a | max_by(.updatedAt // 0) // {}) | .stateStartedAt // 0 | tostring)] | @tsv' <<<"$ps_json")

# 自分の open PR 全部 (draft を含む、どのリポのものも)。"<repo>\t<branch>\t<番号>\t<draft か>\t<CI>\t<head の SHA>"。
# 上の PR 対応の検索は draft を含まず、リポも絞っているので、キューの線とボードのために別に聞く。
open_ok=0
open_prs=""
if [ "$queue_on" = 1 ] || [ -n "$qwts" ]; then
    # shellcheck disable=SC2016  # $q と $endCursor は GraphQL の変数
    if open_prs=$(gh api graphql --paginate -f q="is:pr is:open author:$me" -f query='
query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number isDraft headRefName headRefOid author { login } repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}' 2>/dev/null | jq -r --arg me "$me" '.data.search.nodes[] | select(.author.login == $me)
        | [.repository.nameWithOwner, .headRefName, (.number | tostring), (.isDraft == true | tostring),
           (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"), (.headRefOid // "-")] | @tsv'); then
        open_ok=1
    else
        log "WARN: GitHub から自分の open PR (draft を含む) を取れない。キューの起動とボードは見送り"
        open_prs=""
    fi
fi
# open_pr_of <repo> <branch>: その branch の open PR の行。無ければ空。
open_pr_of() { printf '%s' "$open_prs" | awk -F'\t' -v s="$1" -v b="$2" '$1 == s && $2 == b { print; exit }'; }

# launch_prev <key>: その鍵の、最後から 2 つ目の行の状態 (fail が作成と起動のどちらの失敗かを見分ける)。
launch_prev() { awk -F'\t' -v k="$1" '$4 FS $5 FS $6 == k { p = c; c = $2 } END { print p }' "$LAUNCHES_FILE"; }
# queue_fails <key> <creating|launching>: その T で、作成 (creating の直後) か起動 (launching の直後) が fail で終わった回数。
queue_fails() { awk -F'\t' -v k="$1" -v s="$2" '$4 FS $5 FS $6 == k { if ($2 == "fail" && p == s) c++; p = $2 } END { print c + 0 }' "$LAUNCHES_FILE"; }
# issue_wts <repo> <番号>: その issue の worktree の path (linkedIssue・linkedItems の URL・branch の接頭辞のどれか)。古い順。
# リポは Orca の repoId で見る (worktree の git remote を読めないときも、見えている worktree を見落とさない)。
# 同じリポの clone を Orca に複数登録していれば、その全部を見る (別の clone で進んでいる issue を、もう 1 つ作らない)。
issue_wts() {
    local rids
    rids=$(printf '%s' "$mains" | awk -F'\t' -v s="$1" '$1 == s { print $3 }' | jq -Rsc 'split("\n") | map(select(. != ""))')
    jq -r --argjson rids "${rids:-[]}" --arg n "$2" --arg url "https://github.com/$1/issues/$2" '
        [.result.worktrees[] | select((.repoId as $r | any($rids[]; . == $r)) and (.isMainWorktree | not))
         | select((((.linkedIssue // null) | if type == "object" then .number else . end) | tostring) == $n
             or any((.linkedItems // [])[]; .url == $url)
             or ((.branch // "") | sub("^refs/heads/"; "") | startswith("issue-" + $n + "-")))]
        | sort_by(.createdAt // 0) | .[].path' <<<"$ps_json"
}
# queue_pending <issue>: その issue の最後の記録が creating (作成の結果が分からない) なら 1。
# T をまたいで見る (ラベルを付け直しても、前の作成の結果が分かるまでは次を作らないため)。
queue_pending() { awk -F'\t' -v p="$1" '$4 == p { st = $2 } END { if (st == "creating") print 1 }' "$LAUNCHES_FILE"; }
slugify() {
    local s
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-30 | sed 's/-$//')
    printf '%s' "${s:-work}"
}
# queue_unlabel <repo> <番号> <T>: 起動できた issue のラベルを外す。外せなくても、同じ T では起動し直さない (次の回に外し直す)。
# 外す直前に、今のラベルの T を取り直す。起動した T と違えば外さない: 付け直す前の T の依頼を出し直したときと、
# issue を読んでから起動するまでの間に人が付け直したときは、それが新しい承認なので残す (その worker は着手前の check で止まる)。
queue_unlabel() {
    local cur
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: queue ラベルを外す → $1#$2"
        return 0
    fi
    cur=$(queue_issue "$1" "$2" | jq -r --arg label "$queue_label" "$QUEUE_JQ"'
        .data.viewer.login as $me | .data.repository.issue | verdict($me; $label; ""; ""; "")[1]' 2>/dev/null) || cur=""
    if [ "$cur" != "$3" ]; then
        log "queue: ラベルを外さない → $1#$2 (今のラベルは、起動した承認 $3 のものでないか、確かめられない)"
        return 0
    fi
    if gh issue edit "$2" -R "$1" --remove-label "$queue_label" >/dev/null 2>&1; then
        log "queue: ラベルを外した → $1#$2"
    else
        log "WARN: queue: ラベルを外せない → $1#$2 (次回に外し直す。同じ T では起動し直さない)"
    fi
}
# queue_launch <key> <worktree> <番号> <T> <operationId|-> <印の時刻|空> <repo>: worker を起動し、起動できたらラベルを外す。
# T は起動の引数で渡す (worker は取り直さない。setup を待つ間の変更を、着手の直前の check で拾うため)。
queue_launch() {
    local key=$1 wt=$2 n=$3 t=$4 op=$5 t0=$6 slug=$7 prompt
    t0=${t0:-$(date +%s)}
    prompt="/issue-worker $n --approved-at $t

($(launch_mark "$t0")人は見ていない。判断が要るものはグローバル CLAUDE.md の「委任の線引き」どおり Needs decision に上げて止まる)"
    if launch_agent "$key" "$wt" "$prompt" "$op" "$t0" --model opus --effort high --surface chat; then
        log "queue: worker を起動 → $slug#$n"
        launched=$((launched + 1))
        queue_unlabel "$slug" "$n" "$t"
    else
        log "WARN: queue: worker を起動できなかった → $slug#$n ($(launch_last "$key" | cut -f2)。失敗なら次回に試し直し、返事を失ったなら同じ依頼を出し直す。分からなければ起動し直さない)"
    fi
}
# queue_create <key> <repo> <番号> <T> <題名> <主 checkout> <既定ブランチ>: worktree を作り、続けて worker を起動する。
queue_create() {
    local key=$1 slug=$2 n=$3 t=$4 title=$5 main=$6 base=$7 br out rc=0 wt
    br="issue-$n-$(slugify "$title")"
    launch_log "$key" creating - || {
        log "WARN: worktree を作る記録を書けない。作らない"
        return 1
    }
    # --no-parent: 実行した場所の Orca の親子関係を引き継がせない。cwd は固定する (起動と同じ)。
    out=$(cd "$HOME" && orca worktree create --repo "path:$main" --name "$br" --branch "$br" --issue "$n" \
        --base-branch "origin/$base" --setup run --no-parent --json 2>/dev/null) || rc=$?
    wt=$(jq -r '.result.worktree.path // empty' <<<"$out" 2>/dev/null || true)
    if [ "$rc" != 0 ] || [ -z "$wt" ]; then
        # はっきり失敗と分かるときだけ fail (次の回に試し直す)。返事が読めないときと、Orca の CLI 自身が「結果不明」に
        # 分類しているコード (応答待ちの時間切れ・切断・壊れた応答) は creating のまま残し、すぐには作り直さない
        # (作れていたら worktree が 2 つになる。使用済みの branch 名には Orca が数字を足すので、名前では防げない)。
        if jq -e '.ok == false and ((.error.code // "")
            | test("^(runtime_unavailable|remote_runtime_unavailable|runtime_timeout|invalid_runtime_response)$") | not)' <<<"$out" >/dev/null 2>&1; then
            launch_log "$key" fail - || true
        fi
        log "WARN: queue $slug#$n: worktree を作れなかった ($(launch_last "$key" | cut -f2))"
        return 1
    fi
    # 名前は文字数で切る (GNU の cut -c はバイトで切り、日本語の題名を文字の途中で壊す)。
    orca_set --worktree "path:$wt" --display-name "$(printf '%s: #%s %s' "${slug#*/}" "$n" "$title" | jq -Rr '.[0:60]')" --json ||
        log "WARN: queue $slug#$n: カードの名前を書けない ($wt)"
    log "queue: worktree を作成 $slug#$n → ${wt#"$ORCA_ROOT"/}"
    queue_launch "$key" "$wt" "$n" "$t" - "" "$slug"
}

if [ "$queue_on" = 1 ] && [ "$open_ok" = 1 ]; then
    # shellcheck disable=SC2016  # $q と $endCursor は GraphQL の変数
    if ! queue_issues=$(gh api graphql --paginate \
        -f q="is:issue is:open author:$me label:\"$queue_label\" $(printf '%s\n' "$queue_repos" | sed 's/^/repo:/' | tr '\n' ' ')" -f query='
query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 50, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes { ...Q }
  }
}'"$QUEUE_FRAGMENT" 2>/dev/null |
        jq -rs --arg me "$me" --arg label "$queue_label" --arg al "$(cfg ask_labels "")" \
            --arg aw "$(cfg ask_title_words "$DEFAULT_TITLE_WORDS")" "$QUEUE_JQ"'
            [.[].data.search.nodes[] | select(.number != null)] | sort_by(.createdAt) | .[]
            | verdict($me; $label; ""; $al; $aw) as $v
            | [.repository.nameWithOwner, (.number | tostring), $v[0], ($v[1] | if . == "" then "-" else . end),
               ((.title // "-") | gsub("[\t\r\n]"; " ")), (.repository.defaultBranchRef.name // "-")] | @tsv'); then
        log "WARN: GitHub からキューの issue を取れない。キューは見送り"
        queue_issues=""
    fi

    # 新しい着手を止める線。どれも厳密な上限ではない (進行中の worker が後から PR を出す分は超えうる)。
    max_wip=$(cfg_num max_wip 4)
    max_day=$(cfg_num max_per_day 2)
    max_open=$(cfg_num max_open_prs 0)
    now=$(date +%s)
    day0=$((now - (now + 32400) % 86400)) # 今日 (JST) の 0 時。JST に夏時間は無い
    today=$(awk -F'\t' -v d="$day0" '$2 == "creating" && $5 == "issue-worker" && $1 >= d' "$LAUNCHES_FILE" | wc -l | tr -d ' ')
    n_open=$(printf '%s' "$open_prs" | grep -c . || true)
    # WIP: キュー由来の worktree のうち、open の PR が無い・エージェントが動いている・Needs decision のどれか (Done は除く)。
    # 止まった worker も枠を占有し続ける (失敗が続けば WIP が埋まって新規が止まる)。
    # この回に PR 対応を起動した・Needs decision に上げた worktree も数える (どちらも、回の最初に読んだ状態にはまだ出ていない)。
    wip=0
    while IFS=$'\t' read -r q_slug q_path q_branch _ q_status q_busy _; do
        [ -n "$q_slug" ] || continue
        [ "$q_status" != "completed" ] || continue
        if [ "$q_status" = "needs-decision" ] || [ "$q_busy" != "-" ] || [ -z "$(open_pr_of "$q_slug" "$q_branch")" ] ||
            printf '%s' "$started$raised" | grep -qxF -- "$q_path"; then
            wip=$((wip + 1))
        fi
    done <<<"$qwts"
    # 作成の結果が分からないまま worktree が見えない issue も、枠を占有する (作れていたら、あとから現れる)。
    # 待つ上限を過ぎても現れなければ、作れなかったものとして閉じて枠を空ける (同じ T なら、はっきりした失敗と同じ回数まで
    # 作り直す)。今ラベルの付いている issue に限らず、記録の全部を見る (ラベルを外した・閉じた issue の記録が枠を占有し続けない)。
    # ponytail: 時間で見切る。Orca が一覧を返しているのに、これだけ前に頼んだ作成がまだ途中、ということは考えにくい。
    # 外れると同じ issue の worktree が 2 つになる。Orca の作成に冪等キーが付いたら、それで出し直す形に替える。
    while IFS=$'\t' read -r q_iss q_time q_sig; do
        [ -n "$q_iss" ] || continue
        [ -z "$(issue_wts "${q_iss%#*}" "${q_iss##*#}")" ] || continue
        if [ "$DRY_RUN" != "1" ] && [ "$((now - q_time))" -ge "$LAUNCH_UNKNOWN_AFTER" ] &&
            launch_log "$q_iss"$'\t'"issue-worker"$'\t'"$q_sig" fail -; then
            log "queue: 作成の結果が分からないまま ${LAUNCH_UNKNOWN_AFTER} 秒たち、worktree も現れない。失敗として閉じる → $q_iss"
            continue
        fi
        wip=$((wip + 1))
    done < <(awk -F'\t' '$5 == "issue-worker" { t[$4] = $1; st[$4] = $2; s[$4] = $6 }
        END { for (k in st) if (st[k] == "creating") print k FS t[k] FS s[k] }' "$LAUNCHES_FILE")

    q_new=0
    while IFS=$'\t' read -r slug n verdict t title base; do
        [ -n "$slug" ] || continue
        iss="$slug#$n"
        if [ "$t" = "-" ]; then
            vlog "queue 対象外 $iss ($verdict)"
            continue
        fi
        key="$iss"$'\t'"issue-worker"$'\t'"$t"
        main=$(printf '%s' "$mains" | awk -F'\t' -v s="$slug" '$1 == s { print $2; exit }')
        if [ -z "$main" ]; then
            vlog "queue 対象外 $iss (主 checkout が Orca に登録されていない)"
            continue
        fi
        iwts=$(issue_wts "$slug" "$n")
        wt=$(printf '%s\n' "$iwts" | head -n 1)
        last=$(launch_last "$key" | cut -f2)
        op=- t0=""
        # 作成の結果待ち (creating のまま) も、起動の結果待ち (launch_open) と同じく、T をまたいで issue ごとに見る。
        if [ -z "$last" ] && [ -z "$(launch_open "$iss")" ] && [ -z "$(queue_pending "$iss")" ]; then
            # この T にはまだ手を付けておらず、前の T の作成・起動で結果待ちのものも無い。
            if [ -n "$wt" ]; then
                vlog "queue 対象外 $iss (Orca に worktree がある: ${wt#"$ORCA_ROOT"/})"
                continue
            fi
            if [ "$verdict" != "ok" ]; then
                vlog "queue 対象外 $iss ($verdict)"
                continue
            fi
        else
            # この T で手を付けた issue か、ラベルを付け直す前の T の作成・起動が結果待ちの issue。
            # 観測と記録の最後の行から続きを決める (前の起動の結果が分かるまで、新しい T では作らない)。
            # 同じ issue の worktree が 2 つ以上あれば、古い方だけ使い、新しい方は人に上げる。
            while IFS= read -r extra; do
                [ -z "$extra" ] || board "$extra" queue-dup "$t" needs-decision "同じ issue の worktree が 2 つある。こちらは自動では使わない: #$n"
            done <<<"$(printf '%s\n' "$iwts" | sed 1d)"
            case "$last" in
            launched)
                # 起動できたのにラベルが残っている (外し損ねた)。
                queue_unlabel "$slug" "$n" "$t"
                continue
                ;;
            unknown)
                vlog "keep  $iss (worker を起動できたか分からないまま閉じた。人が見る)"
                continue
                ;;
            esac
            # 結果待ちの起動は issue ごとに見る (ラベルの付け直しで T が変わっても、前の起動の結果が分かるまでは次を起動しない)。
            o_time="" o_op="" o_action="" o_sig=""
            IFS=$'\t' read -r o_time o_op o_action o_sig <<<"$(launch_open "$iss")" || true
            if [ -n "$o_time" ]; then
                o_key="$iss"$'\t'"$o_action"$'\t'"$o_sig"
                if [ -n "$wt" ] && launch_seen "$wt" "$o_time"; then
                    launch_close "$o_key" launched
                    log "queue: worker を起動できていた → $iss (返事は読めなかったが、この起動のエージェントを確認)"
                    queue_unlabel "$slug" "$n" "$o_sig"
                    continue
                fi
                if [ "$(($(date +%s) - o_time))" -ge "$LAUNCH_UNKNOWN_AFTER" ]; then
                    # 待っても、この起動のエージェントが現れない。出し直しをやめ、起動したものとして閉じる
                    # (同じ T では二度と起動しない)。人に上げ、書けたのを確かめてから閉じる。
                    if [ "$o_key" = "$key" ] && [ -n "$wt" ]; then
                        board "$wt" queue-launch-unknown "$t" needs-decision "worker を起動できたか分からない: #$n"
                        grep -qxF -- "$wt"$'\t'"queue-launch-unknown"$'\t'"$t" "$BOARD_FILE" || continue
                    fi
                    launch_close "$o_key" unknown
                    continue
                fi
                if [ "$o_op" = "-" ]; then
                    vlog "keep  $iss (worker の起動の結果が分からない。起動し直さずに待つ)"
                    continue
                fi
                # 返事を失った起動。今の状態ではなく、失った依頼そのもの (同じ T、同じ印) を同じ operationId で出し直す。
                key=$o_key t=$o_sig op=$o_op t0=$o_time last=lost
            fi
            if [ -z "$wt" ]; then
                # 作成がはっきり失敗した (creating の直後の fail) ときだけ、同じ T で 3 回まで作り直す。
                # creating のまま (結果が分からない) は作り直さずに待つ (作れていたら 2 つになる。枠は占有する)。
                if [ "$(launch_prev "$key") $last" != "creating fail" ] || [ "$verdict" != "ok" ] ||
                    [ "$(queue_fails "$key" creating)" -ge "$MAX_ATTEMPTS" ]; then
                    vlog "keep  $iss (worktree が見えない。最後の記録: ${last:-前の T の creating}。作り直さない)"
                    continue
                fi
            else
                # worktree がある (作れた)。worker の起動 (手順 2) が要るか。
                if [ "$op" = "-" ] && [ "$(jq -r --arg p "$wt" '[.result.worktrees[] | select(.path == $p) | .agents[]?] | length' <<<"$ps_json")" != 0 ]; then
                    vlog "keep  $iss (worker を起動していないのに、エージェントが居る。触らない)"
                    continue
                fi
                fails=$(queue_fails "$key" launching)
                if [ "$op" = "-" ] && [ "$fails" -ge "$MAX_ATTEMPTS" ]; then
                    board "$wt" queue-launch-fail "$t" needs-decision "worker の起動に $fails 回失敗: #$n"
                    continue
                fi
                if [ "$op" = "-" ] && [ "$verdict" != "ok" ]; then
                    # worktree を作ったあと、起動の前に対象外になった (no-agent が付いた、本文が編集された など)。
                    # worker を起動して着手前の再確認で止めさせるのではなく、起動せずに人に上げる。出し直し (op あり) は別扱い。
                    board "$wt" queue-not-ready "$t" needs-decision "起動の前に対象外になった: #$n ($verdict)"
                    continue
                fi
                # 人の作業を踏まない。作ったあと起動の前に、人がエージェントを使わずに編集していることがある (PR 対応と同じ見方。
                # 状態を読めないときも起動しない)。出し直し (op あり) は、最初の依頼で動き出した worker の変更がありうるので見ない。
                if [ "$op" = "-" ] && { ! dirty=$(git -C "$wt" --no-optional-locks status --porcelain 2>/dev/null) || [ -n "$dirty" ]; }; then
                    board "$wt" queue-dirty "$t" - "未コミットの変更があるので、worker の起動を見送り: #$n"
                    continue
                fi
                [ "$braked" = 0 ] || continue
                if [ "$(jq -r --arg p "$wt" '[.result.worktrees[] | select(.path == $p) | .workspaceStatus // ""][0] // ""' <<<"$ps_json")" = "needs-decision" ] ||
                    printf '%s' "$raised" | grep -qxF -- "$wt"; then
                    vlog "keep  $iss (worker の起動を待つ worktree が Needs decision でユーザーの判断待ち)"
                    continue
                fi
                if printf '%s' "$hold" | grep -qxF -- "$wt"; then
                    vlog "keep  $iss (再開したセッションに指示が入るのを待っている)"
                    continue
                fi
                if [ "$launched" -ge "$MAX_LAUNCHES" ]; then
                    vlog "keep  $iss (今回の起動上限 $MAX_LAUNCHES に達した。次回)"
                    continue
                fi
                if [ "$DRY_RUN" = "1" ]; then
                    log "DRY-RUN: queue worker を起動 → $iss (${wt#"$ORCA_ROOT"/})"
                    launched=$((launched + 1))
                    continue
                fi
                queue_launch "$key" "$wt" "$n" "$t" "$op" "$t0" "$slug"
                continue
            fi
        fi

        # 新しい着手 (worktree を作って起動する)。1 回に 1 件、線を全部満たす間だけ。
        [ "$braked" = 0 ] || continue
        if [ "$q_new" = 1 ]; then
            vlog "keep  $iss (キューの着手は 1 回に 1 件。次回)"
            continue
        fi
        why=""
        if [ "$launched" -ge "$MAX_LAUNCHES" ]; then
            why="今回の起動上限 ($launched/$MAX_LAUNCHES)"
        elif [ "$wip" -ge "$max_wip" ]; then
            why="max_wip ($wip/$max_wip)"
        elif [ "$today" -ge "$max_day" ]; then
            why="max_per_day ($today/$max_day)"
        elif [ "$n_open" -ge "$max_open" ]; then
            why="max_open_prs ($n_open/$max_open)"
        elif [ "$n_wt" -ge "$max_wt" ]; then
            why="max_worktrees ($n_wt/$max_wt)"
        elif [ "$base" = "-" ]; then
            why="既定ブランチが分からない"
        fi
        if [ -n "$why" ]; then
            vlog "queue 見送り $iss ($why)"
            continue
        fi
        q_new=1
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY-RUN: queue worktree を作って worker を起動 → $iss"
            launched=$((launched + 1))
            continue
        fi
        queue_create "$key" "$slug" "$n" "$t" "$title" "$main" "$base" || true
    done <<<"$queue_issues"
fi

# ---- PR がマージ・クローズされた worktree のカードを Done に移す ----
# worktree を消すのは worktree-gc (1 時間ごと) なので、それまでの間 In progress や In review に残って紛らわしい。
# GitHub Projects の既定の自動化 (マージされた PR を Done にする) と同じ形。
# worktree-gc が消さないもの (エージェントが作業中・入力待ち) と、同じブランチで OPEN の PR があるものは動かさない。
# macOS の date は -v、テストを回す CI (Linux) の date は -d。
closed_since=$(date -v-14d +%Y-%m-%d 2>/dev/null || date -d '14 days ago' +%Y-%m-%d)
closed_ok=1
# shellcheck disable=SC2016  # $q は GraphQL の変数。シェルに展開させない
closed_prs=$(gh api graphql --paginate -f q="is:pr is:closed author:$me closed:>=$closed_since $repos" -f query='
query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { number state headRefName repository { nameWithOwner } } }
  }
}' --jq '.data.search.nodes[] | [.repository.nameWithOwner, .headRefName, (.number | tostring), .state] | @tsv' 2>/dev/null) || {
    log "WARN: GitHub からクローズ済みの PR を取れない。Done への移動は見送り"
    closed_prs=""
    closed_ok=0
}
moved_to_done=""
while IFS=$'\t' read -r slug branch num state; do
    [ -n "$slug" ] || continue
    line=$(printf '%s' "$worktrees" | awk -F'\t' -v s="$slug" -v b="$branch" '$1 == s && $2 == b { print; exit }')
    [ -n "$line" ] || continue
    wt=$(printf '%s' "$line" | cut -f3)
    [ "$(printf '%s' "$line" | cut -f4)" = "completed" ] && continue
    # 同じブランチに OPEN の PR があれば作業は続いている。$prs は draft と他人の PR を含まないので、ここで別に聞く。
    open_count=$(gh pr list -R "$slug" --head "$branch" --state open --json number -q 'length' 2>/dev/null) || continue
    [ "$open_count" = "0" ] || continue
    busy=$(jq -r --arg p "$wt" '[.result.worktrees[]? | select(.path == $p) | .agents[]?.state | select(. != "done")] | join(",")' <<<"$ps_json")
    if [ -n "$busy" ]; then
        vlog "keep  $slug#$num ($state だがエージェントが $busy)"
        continue
    fi
    board "$wt" closed-pr "$state#$num" completed "$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]') #${num}（worktree-gc の削除待ち）"
    moved_to_done="$moved_to_done$wt"$'\n'
done <<<"$closed_prs"

# ---- キュー由来の worktree のボード ----
#   draft の PR があり、エージェントが終わり、CI が緑 → 未読と「ready 判断」(draft は自動保守しない。ready にするのは人)
#   PR が無いまま、エージェントが全部終わった → Needs decision「PR を出さずに終了」(利用上限・異常終了を含む)
#   working のまま QUEUE_STALL_AFTER 更新が無い → 未読と「停止の疑い」
if [ -n "$qwts" ] && [ "$open_ok" = 1 ]; then
    now_ms=$(($(date +%s) * 1000))
    while IFS=$'\t' read -r q_slug q_path q_branch q_n q_status q_busy q_agents q_upd q_started; do
        [ -n "$q_slug" ] || continue
        [ "$q_status" != "completed" ] || continue
        ! printf '%s' "$moved_to_done" | grep -qxF -- "$q_path" || continue
        q_pr=$(open_pr_of "$q_slug" "$q_branch")
        if [ -n "$q_pr" ]; then
            IFS=$'\t' read -r _ _ q_num q_draft q_ci q_oid <<<"$q_pr"
            if [ "$q_draft" = "true" ] && [ "$q_busy" = "-" ] && [ "$q_ci" = "SUCCESS" ]; then
                board "$q_path" queue-ready "$q_oid" - "ready 判断: #$q_num"
            fi
        elif [ "$closed_ok" = 1 ] && [ "$q_agents" -gt 0 ] && [ "$q_busy" = "-" ] && [ "$q_status" != "needs-decision" ] &&
            ! printf '%s' "$raised" | grep -qxF -- "$q_path" && ! printf '%s' "$hold" | grep -qxF -- "$q_path"; then
            # クローズ済みの PR が読めない回は、マージ済みの worktree と見分けられないので出さない。
            board "$q_path" queue-no-pr "$q_started" needs-decision "PR を出さずに終了: #$q_n"
        fi
        case ",$q_busy," in
        *,working,*)
            if [ "$q_upd" -gt 0 ] && [ "$((now_ms - q_upd))" -ge "$((QUEUE_STALL_AFTER * 1000))" ]; then
                board "$q_path" queue-stalled "$q_upd" - "停止の疑い: #${q_n}（$((QUEUE_STALL_AFTER / 3600)) 時間更新が無い）"
            fi
            ;;
        esac
    done <<<"$qwts"
fi

# ---- エージェントの状態をボードに出す (PR の有無に関係なく、Orca の全 worktree が対象) ----
# 最新のエージェント 1 体を見る。waiting は Orca が入力待ちと判定したもの。
# done でも、最後の発言が質問なら人待ちなので、列は動かさず未読と「要確認」だけ付ける。
# 発言の改行は 1 行 1 worktree に収めるため " ⏎ " にして渡し、ループの中で戻す。
while IFS=$'\t' read -r wt board state since last; do
    [ -n "$wt" ] || continue
    [ "$board" = "needs-decision" ] && continue
    # Done のカードは worktree-gc の削除待ちなので、最後の発言が質問でも人には上げない。
    [ "$board" = "completed" ] && continue
    printf '%s' "$moved_to_done" | grep -qxF -- "$wt" && continue
    last=${last// ⏎ /$'\n'}
    first=$(printf '%s' "$last" | awk 'NF' | tail -n 1 | cut -c1-80)
    if [ "$state" = "waiting" ]; then
        board "$wt" waiting "$since" needs-decision "入力待ち: ${first:-エージェントが入力を待っている}"
    elif [ "$state" = "done" ] && looks_like_question "$last"; then
        board "$wt" question "$since" - "要確認: $first"
    fi
done < <(jq -r --arg root "$ORCA_ROOT" '
    .result.worktrees[]?
    | select((.isMainWorktree | not) and (.path | startswith($root + "/")) and ((.agents // []) | length > 0))
    | (.agents | max_by(.updatedAt // 0)) as $a
    | [.path, ((.workspaceStatus // "") | if . == "" then "-" else . end), $a.state, (($a.stateStartedAt // 0) | tostring),
       (($a.lastAssistantMessage // "") | gsub("[\t\r]"; " ") | gsub("\n"; " ⏎ "))] | @tsv' <<<"$ps_json")

if [ "$launched" -gt 0 ] || [ "$flagged" -gt 0 ]; then
    log "完了 (起動: $launched, ボード: $flagged)"
fi
