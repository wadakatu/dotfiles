#!/usr/bin/env bash
#
# 自分の OPEN な PR を見て、対応が要るものに Orca のタブでエージェントを起動する。
# 対象は Orca に worktree がある非 draft の PR だけ。
#   conflict → /sync-pr、CI 失敗 → /fix-ci、未対応のレビュー → /review-pr-comments
# あわせて、人の判断待ちになったものを Orca のボードに出す。
#   同じ対応を MAX_ATTEMPTS 回起動しても直らない PR → Needs decision
#   CLEAN で auto-merge の無い PR (マージするかは人が決める) → Needs decision
#   入力待ち (waiting) のエージェント → Needs decision
#   文章で質問して止まったエージェント (Orca では done に見える) → 未読と「要確認」のコメントだけ付ける
#   PR がマージ・クローズされた worktree → Done (worktree-gc が消すまでの置き場所)
# launchd からログイン時と数分ごとに実行される。定義は home/pr-dispatch.nix。
#
# 1 回の流れ: ロック → 再開 (agent-resume.sh) → 観測 (Orca と GitHub) → 再開待ちの解除 → PR 対応の起動 → ボード。
# 再開を先に、同じロックの中で動かすのは、再開するセッションと PR 対応のエージェントを同じ worktree に並べないため。
# 観測が欠けた回 (Orca や GitHub に届かない、一覧が途中で切れた) は何も起動しない。
# 結果の分からない起動は、自動ではやり直さない (起動できていたら 2 体並ぶ)。
#
# 止めるとき: ~/Library/Application Support/pr-dispatch/BRAKE を置く (空でよい)。再開と起動が止まり、ボードの更新は続く。
#
# 手で確認するとき:
#   DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/pr-dispatch.sh
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
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
# 数分ごとに同じ内容が並ぶ見送りの理由は、VERBOSE=1 のときだけ出す。
vlog() { [ "$VERBOSE" = "1" ] && log "$@"; return 0; }

flagged=0
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
    local args=(--worktree "path:$wt" --comment "$comment" --json) out
    [ "$status" = "completed" ] || args+=(--unread)
    [ "$status" = "-" ] || args+=(--workspace-status "$status")
    # 列を作り直して内部名が変わると、exit 0 でも warnings が返って列は動かない。
    # 書けたことにして覚えると、その通知は二度と出ないので、warnings があれば書けていない扱いにする。
    if out=$(orca worktree set "${args[@]}" 2>/dev/null) &&
        jq -e '[.. | objects | .warnings? // empty | .[]?] | length == 0' <<<"$out" >/dev/null 2>&1; then
        printf '%s\n' "$key" >>"$BOARD_FILE"
        log "board $reason → ${wt#"$ORCA_ROOT"/}: $comment"
        flagged=$((flagged + 1))
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
touch "$STATE_FILE" "$BOARD_FILE" "$LAUNCHES_FILE"

# ---- Orca の worktree: "<owner/repo>\t<branch>\t<path>\t<board status>" ----
wt_json=$(orca worktree list --json 2>/dev/null) || {
    log "WARN: Orca の worktree の一覧を取れない。見送り"
    exit 0
}
worktrees=""
while IFS=$'\t' read -r wt_path branch status; do
    [ -n "$branch" ] || continue
    slug=$(git -C "$wt_path" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') || continue
    [ -n "$slug" ] || continue
    worktrees="$worktrees$slug"$'\t'"$branch"$'\t'"$wt_path"$'\t'"$status"$'\n'
done < <(jq -r --arg root "$ORCA_ROOT" '
    .result.worktrees[]
    | select((.isMainWorktree | not) and (.path | startswith($root + "/")))
    | [.path, ((.branch // "") | sub("^refs/heads/"; "")), (.workspaceStatus // "")] | @tsv' <<<"$wt_json")

if [ -z "$worktrees" ]; then
    log "Orca の worktree が無い。終了"
    exit 0
fi

# ---- PR の状態を 1 回の問い合わせで取る (検索は worktree のあるリポに絞る) ----
repos=$(printf '%s' "$worktrees" | cut -f1 | sort -u | sed 's/^/repo:/' | tr '\n' ' ')
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
prs=$(jq -r --arg me "$me" '.data.search.nodes[]
    | [ .repository.nameWithOwner, .headRefName, (.number | tostring), .url, .headRefOid, .mergeable,
        (.commits.nodes[0].commit.statusCheckRollup.state // "NONE"),
        (if .reviewThreads.pageInfo.hasNextPage then "?" else
          ([.reviewThreads.nodes[] | select((.isResolved | not) and (.comments.nodes[0].author.login != $me))
            | .comments.nodes[0].id] | sort | join(",") | if . == "" then "-" else . end) end),
        .mergeStateStatus, (if .autoMergeRequest then "auto" else "manual" end) ] | @tsv' <<<"$prs_json") || {
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
launch_log() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$2" "$3" "$1" >>"$LAUNCHES_FILE"; }
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
# launch_agent <key> <worktree> <prompt> <operationId|->: エージェントを起動する。起動できたら 0。
# 起動の前に launching、結果が分かったら launched / lost / fail を書く。どれも書かれなければ結果不明。
launch_agent() {
    local key=$1 wt=$2 prompt=$3 op=$4 out rc=0 newop
    local args=(agent launch --agent claude --worktree "path:$wt" --prompt "$prompt" --json)
    # 返事を失った起動は、新しく起動し直さず、同じ依頼を出し直す (orca agent launch --help の --retry-launch)。
    [ "$op" = "-" ] || args+=(--retry-launch "$op")
    launch_log "$key" launching "$op" || {
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

launched=0
while IFS=$'\t' read -r slug branch num url head mergeable ci threads merge_state merge_mode; do
    [ -n "$slug" ] || continue
    line=$(printf '%s' "$worktrees" | awk -F'\t' -v s="$slug" -v b="$branch" '$1 == s && $2 == b { print; exit }')
    [ -n "$line" ] || continue
    wt=$(printf '%s' "$line" | cut -f3)
    board=$(printf '%s' "$line" | cut -f4)
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
        # 対応が要らない PR。CLEAN で auto-merge が無ければ、マージするかは人が決める。
        if [ "$merge_state" = "CLEAN" ] && [ "$merge_mode" = "manual" ] && [ "$board" != "needs-decision" ]; then
            board "$wt" merge "$head" needs-decision "マージ判断: #${num}（CLEAN・auto-merge なし）"
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
    key="$pr"$'\t'"$action"$'\t'"$sig"

    # この PR の前の起動の結果が分かっていなければ、それを先に片付ける。push やレビューで状態が変わっていても、
    # 結果が分かるまで別の起動はしない (起動できていたら 2 体並ぶ)。
    o_time="" o_op="" o_action="" o_sig=""
    IFS=$'\t' read -r o_time o_op o_action o_sig <<<"$(launch_open "$pr")" || true
    op=-
    if [ -n "$o_time" ]; then
        o_key="$pr"$'\t'"$o_action"$'\t'"$o_sig"
        if jq -e --arg p "$wt" --argjson t "$((o_time * 1000))" \
            '[.result.worktrees[] | select(.path == $p) | .agents[]? | select((.stateStartedAt // 0) >= $t)] | length > 0' <<<"$ps_json" >/dev/null; then
            # 起動の後に動き出したエージェントが居る (前から居て終わっているエージェントは数えない)。起動できていた。
            launch_close "$o_key" launched
            log "launch $o_action → $pr (返事は読めなかったが、起動後のエージェントを確認)"
            continue
        fi
        if [ "$(($(date +%s) - o_time))" -ge "$LAUNCH_UNKNOWN_AFTER" ]; then
            # 待っても起動後のエージェントが現れない。これ以上は待たず、出し直しもせず、起動したものとして閉じる
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
            action=$o_action sig=$o_sig key=$o_key op=$o_op
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
    if ! dirty=$(git -C "$wt" status --porcelain 2>/dev/null) || [ -n "$dirty" ]; then
        board "$wt" "dirty-$action" "$sig" - "未コミットの変更があるので、自動の /$action を見送り: #$num"
        continue
    fi
    if [ "$launched" -ge "$MAX_LAUNCHES" ]; then
        vlog "keep  $pr ($action: 今回の起動上限 $MAX_LAUNCHES に達した。次回)"
        continue
    fi

    prompt="/$action $url

(pr-dispatch による自動起動。人は見ていない。判断が要るものはグローバル CLAUDE.md の「委任の線引き」どおり Needs decision に上げて止まる)"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: launch $action → $pr ($wt)"
        launched=$((launched + 1))
        continue
    fi
    if launch_agent "$key" "$wt" "$prompt" "$op"; then
        printf '%s\n' "$key" >>"$STATE_FILE"
        orca worktree set --worktree "path:$wt" --comment "auto: $action (#$num)" --json >/dev/null 2>&1 || true
        log "launch $action → $pr"
        launched=$((launched + 1))
    else
        log "WARN: 起動できなかった $action → $pr ($(launch_last "$key" | cut -f2)。失敗なら次回に試し直し、返事を失ったなら同じ依頼を出し直す。分からなければ起動し直さない)"
    fi
done <<<"$prs"

# ---- PR がマージ・クローズされた worktree のカードを Done に移す ----
# worktree を消すのは worktree-gc (1 時間ごと) なので、それまでの間 In progress や In review に残って紛らわしい。
# GitHub Projects の既定の自動化 (マージされた PR を Done にする) と同じ形。
# worktree-gc が消さないもの (エージェントが作業中・入力待ち) と、同じブランチで OPEN の PR があるものは動かさない。
# macOS の date は -v、テストを回す CI (Linux) の date は -d。
closed_since=$(date -v-14d +%Y-%m-%d 2>/dev/null || date -d '14 days ago' +%Y-%m-%d)
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
