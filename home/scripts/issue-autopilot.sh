#!/usr/bin/env bash
#
# 自分が author の open issue を拾い、issue ごとに Orca の worktree とエージェントを起動して draft PR まで進める。
# 設計は docs/issue-autopilot-design.md。機械的に決まること (候補・重複・上限・ロック・状態遷移) だけをここで行い、
# 「一人で進めてよいか」の判定は /issue-autopilot (dispatcher)、実装は /issue-worker が行う。
#
#   candidates            precheck。sweep の後、未判定と実行待ちを出す。両方 0 なら exit 1
#   verdict <N> go|ask|skip "<理由>" [読んだ updatedAt]   判定を書く (go は実行待ちを作る。版が違えば exit 3)
#   dispatch              実行待ちの起動と、起動途中 (launching) の復旧。起動はすべてここと resume から
#   resume <N> "<指示>"    起動済みの job を同じ worktree で再開する
#   recheck <N>           着手直前の再確認。ok / gone / pr-exists / owner / changed / error を出す
#   done <N> <pr-url>     成功の記録 (worker が呼ぶ)
#   fail <N> <code> [補足] 失敗の記録 (worker が呼ぶ)。カードを Needs decision にする
#   go <N> / skip <N>     人の答え
#   status                設定・job・当日の起動数
#   register              設定の雛形を置き、automation を create / edit する
#
# 対象リポ固有の値 (repo・checkout・ask にするラベル・カード名の接頭辞) は state の config に置き、ここには書かない。
# DRY_RUN=1 は Orca への書き込み (worktree 作成・起動・カード) をせずログに出す。dispatch は予約の前で止まる。
#
set -euo pipefail

PATH="$PATH:/etc/profiles/per-user/${USER:-$(id -un)}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

STATE_DIR="${ISSUE_AUTOPILOT_DIR:-$HOME/Library/Application Support/issue-autopilot}"
LOG_FILE="${ISSUE_AUTOPILOT_LOG:-$HOME/Library/Logs/issue-autopilot.log}"
SELF="${ISSUE_AUTOPILOT_SELF:-$HOME/www/personal/dotfiles/home/scripts/issue-autopilot.sh}"
CONFIG="$STATE_DIR/config"
VERDICTS="$STATE_DIR/verdicts.tsv"   # key updatedAt verdict reason decided_at
JOBS="$STATE_DIR/jobs.tsv"           # key status branch worktreeId operationId paneKey prUrl started_at updated_at note
LAUNCHES="$STATE_DIR/launches.log"   # run_id ts day key reserved|launched|failed
BOARD="$STATE_DIR/board.tsv"         # selector last_comment
LOCK="$STATE_DIR/lock.d"
BOARD_RETRY="$STATE_DIR/board-retry.tsv" # selector status comment (送れなかったカード)
DRY_RUN="${DRY_RUN:-0}"
NOW="${ISSUE_AUTOPILOT_NOW:-$(date +%s)}"
TODAY=$(TZ=Asia/Tokyo date +%F)
DEFAULT_TITLE_WORDS="security —,infra —,本番,prd,prod,個人情報,PII,Secret"

log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$line" >&2
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}
die() { log "ERROR: $*"; exit 2; }
# タブと改行を潰し、空なら "-"。IFS=$'\t' の read はタブの連続を 1 つに詰めるので、空欄を作らない。
clean() { local s; s=$(printf '%s' "$*" | tr '\t\n\r' '   '); printf '%s' "${s:--}"; }

# ---- config (key=value。人が編集する) ----
cfg() { # cfg <key> [default]
    local v
    v=$(awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$CONFIG" 2>/dev/null || true)
    printf '%s' "${v:-${2:-}}"
}
cfg_set() {
    awk -v k="$1" 'index($0, k "=") != 1' "$CONFIG" >"$CONFIG.tmp"
    printf '%s=%s\n' "$1" "$2" >>"$CONFIG.tmp"
    mv "$CONFIG.tmp" "$CONFIG"
}
load_cfg() {
    [ -r "$CONFIG" ] || die "config が無い: $CONFIG (register で雛形を置く)"
    REPO=$(cfg repo); CHECKOUT=$(cfg checkout); BASE=$(cfg base main)
    DISPATCHER=$(cfg dispatcher_worktree); PREFIX=$(cfg card_prefix "${REPO#*/}")
    [ -n "$REPO" ] && [ -n "$CHECKOUT" ] || die "config に repo と checkout が要る"
}
# 起動してよいか。読めない・dispatch_enabled が true でない・cooldown 中は止める (fail closed)。
dispatch_allowed() {
    [ "$(cfg dispatch_enabled)" = "true" ] || { log "dispatch_enabled が true でない。起動しない"; return 1; }
    local until; until=$(cfg cooldown_until)
    if [ -n "$until" ] && [ "$until" -gt "$NOW" ] 2>/dev/null; then
        log "cooldown 中 (until $until)。起動しない"; return 1
    fi
}

# ---- ロック: state を書く全サブコマンドが取り、取ってから読む ----
LOCKED=0
lock() {
    [ "$LOCKED" = 1 ] && return 0
    mkdir -p "$STATE_DIR"
    local i=0 p
    while ! mkdir "$LOCK" 2>/dev/null; do
        p=$(cat "$LOCK/pid" 2>/dev/null || true)
        if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && mkdir "$LOCK.reclaim" 2>/dev/null; then
            # 回収も 1 プロセスだけ。取ったあとで pid を読み直し、別の所有者に替わっていれば消さない
            # ponytail: 回収中に落ちると lock.reclaim が残る。そのときは手で消す (ログの「ロックが空かない」で気づく)
            if [ "$(cat "$LOCK/pid" 2>/dev/null || true)" = "$p" ]; then log "死んだロックを回収 (pid $p)"; rm -rf "$LOCK"; fi
            rmdir "$LOCK.reclaim"; continue
        fi
        i=$((i + 1)); [ "$i" -ge 60 ] && die "ロックが空かない (pid ${p:-?})"
        sleep 1
    done
    echo $$ >"$LOCK/pid"
    LOCKED=1
    trap 'rm -rf "$LOCK"' EXIT
    touch "$VERDICTS" "$JOBS" "$LAUNCHES" "$BOARD" "$BOARD_RETRY"
}

# ---- TSV (1 列目がキー) ----
tsv_get() { awk -F'\t' -v k="$2" '$1 == k { print; exit }' "$1"; }
tsv_del() { awk -F'\t' -v k="$2" '$1 != k' "$1" >"$1.tmp"; mv "$1.tmp" "$1"; }
tsv_put() { # 置換後の全体を一時ファイルに作ってから 1 回の rename で入れ替える
    # 値は ENVIRON で渡す（-v は \n や \t を展開して列・行を壊す）
    TSV_LINE="$2" awk -F'\t' -v k="${2%%$'\t'*}" '$1 != k { print } END { print ENVIRON["TSV_LINE"] }' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}
key() { printf '%s#%s' "$REPO" "$1"; }

job_load() { # job_load <N>: J_* に読む。無ければ 1
    local line; line=$(tsv_get "$JOBS" "$(key "$1")")
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r J_KEY J_STATUS J_BRANCH J_WT J_OP J_PANE J_PR J_START J_UPD J_NOTE <<<"$line"
}
job_new() {
    J_KEY=$(key "$1"); J_STATUS=pending; J_BRANCH=-; J_WT=-; J_OP=-; J_PANE=-; J_PR=-; J_START=-; J_NOTE=-
}
job_save() {
    J_UPD=$NOW
    tsv_put "$JOBS" "$(printf '%s\t' "$J_KEY" "$J_STATUS" "$J_BRANCH" "$J_WT" "$J_OP" "$J_PANE" "$J_PR" "$J_START" "$J_UPD")$(clean "$J_NOTE")"
}
jobs_with() { awk -F'\t' -v s=" $* " 'index(s, " " $2 " ") { sub(/.*#/, "", $1); print $1 }' "$JOBS"; }
event() { printf '%s\t%s\t%s\t%s\t%s\n' "${RUN_ID:--}" "$NOW" "$TODAY" "$(key "$1")" "$2" >>"$LAUNCHES"; }
verdict_put() { # verdict_put <N> <updatedAt> <verdict> <reason>
    tsv_put "$VERDICTS" "$(key "$1")"$'\t'"$2"$'\t'"$3"$'\t'"$(clean "$4")"$'\t'"$NOW"
}

# ---- Orca のカード。同じコメントは打ち直さない (人が消した未読を付け直さない) ----
board() { # board <selector> <status|-> <comment>
    local sel=$1 status=$2 comment=$3 prev
    [ -n "$sel" ] && [ "$sel" != "path:" ] || { log "board (カード未設定): $comment"; return 0; }
    prev=$(awk -F'\t' -v k="$sel" '$1 == k { v = $2 } END { print v }' "$BOARD")
    [ "$prev" = "$comment" ] && return 0
    if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: board $sel ($status) $comment"; return 0; fi
    local args=(worktree set --worktree "$sel" --comment "$comment" --json)
    case "$status" in
        -) ;;
        in-progress) args+=(--workspace-status "$status" --read) ;;
        *) args+=(--workspace-status "$status" --unread) ;;
    esac
    if orca "${args[@]}" >/dev/null 2>&1; then
        tsv_put "$BOARD" "$sel"$'\t'"$comment"
        tsv_del "$BOARD_RETRY" "$sel"
        log "board $sel: $comment"
    else
        tsv_put "$BOARD_RETRY" "$sel"$'\t'"$status"$'\t'"$comment"
        log "WARN: カードに書けない $sel (次回に再試行)"
    fi
}
board_retry() { # 送れなかったカードを送り直す (状態遷移とは別に、成功するまで残す)
    local sel st c
    while IFS=$'\t' read -r sel st c; do [ -n "$sel" ] && board "$sel" "$st" "$c"; done < <(cat "$BOARD_RETRY")
}
# worktree の無い判断待ちを dispatcher のカードに 1 行で集める。対象は最後の candidates で open だった issue。
refresh_asks() {
    local open="$STATE_DIR/open.txt" items n
    [ -f "$open" ] || return 0
    items=$(awk -F'\t' -v r="$REPO#" 'NR == FNR { open[$1] = 1; next }
        index($1, r) == 1 && $3 == "ask" { n = substr($1, length(r) + 1); if (n in open) printf "#%s %s\n", n, substr($4, 1, 30) }' \
        "$open" "$VERDICTS")
    n=$(printf '%s' "$items" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        board "path:$DISPATCHER" in-progress "判断待ち 0"
    else
        board "path:$DISPATCHER" needs-decision "判断待ち $n: $(printf '%s\n' "$items" | awk 'NF { printf "%s%s", (c++ ? " / " : ""), $0 }')"
    fi
}

# ---- Orca の状態 ----
orca_lists() {
    LIST_JSON=$(orca worktree list --json 2>/dev/null) && PS_JSON=$(orca worktree ps --json 2>/dev/null) || return 1
    jq -e '.ok == true and (.result.truncated != true)' <<<"$LIST_JSON" >/dev/null &&
        jq -e '.ok == true and (.result.truncated != true)' <<<"$PS_JSON" >/dev/null || return 1
    REPO_ID=$(jq -r --arg p "$CHECKOUT" '[.result.worktrees[] | select(.isMainWorktree and .path == $p) | .repoId][0] // empty' <<<"$LIST_JSON")
    [ -n "$REPO_ID" ] || { log "Orca に checkout が無い: $CHECKOUT"; return 1; }
}
# issue に紐づく worktree の id。linkedIssue・linkedItems の URL・branch の接頭辞のどれか。
wt_for_issue() {
    jq -r --arg rid "$REPO_ID" --arg n "$1" --arg url "https://github.com/$REPO/issues/$1" '
        .result.worktrees[] | select(.repoId == $rid and (.isMainWorktree | not))
        | select((.linkedIssue // null | if type == "object" then .number else . end | tostring) == $n
            or any((.linkedItems // [])[]; .url == $url)
            or ((.branch // "") | sub("^refs/heads/"; "") | startswith("issue-" + $n + "-")))
        | .id' <<<"$LIST_JSON"
}
wt_by_branch() { # 予約した branch。Orca は取られた名前に数字の接尾辞を付ける
    jq -r --arg rid "$REPO_ID" --arg b "$1" '[.result.worktrees[] | select(.repoId == $rid)
        | select((.branch // "") | sub("^refs/heads/"; "") | test("^" + $b + "(-[0-9]+)?$"))
        | [.id, (.branch | sub("^refs/heads/"; ""))] | @tsv][0] // empty' <<<"$LIST_JSON"
}
wt_exists() { jq -e --arg w "$1" 'any(.result.worktrees[]; .id == $w)' <<<"$LIST_JSON" >/dev/null; }
agent_for() { # agent_for <wt> <N> [除く paneKey] → paneKey。既定で resume 前の pane を除く
    local ex; ex=$({ [ -z "${3:-}" ] || echo "$3"; cat "$STATE_DIR/prompts/$2.exclude" 2>/dev/null || true; } | jq -R . | jq -s .)
    jq -r --arg w "$1" --arg re "^/issue-worker $2( |$)" --argjson ex "$ex" '
        [.result.worktrees[] | select(.worktreeId == $w) | .agents[]?
         | select(((.prompt // "") | test($re)) and (.paneKey as $p | $ex | index([$p]) | not))] | max_by(.updatedAt // 0) // empty | .paneKey' <<<"$PS_JSON"
}
agent_alive() { # done / idle / 消失 以外（working・waiting・不明な状態）は生きているとみなす
    case "$(agent_state "$1" "$2" | cut -f1)" in "" | done | idle) return 1 ;; *) return 0 ;; esac
}
save_prompt() { # 起動の指示を launching を書く前に残す（途中で落ちても recover が同じ指示で起動する）
    mkdir -p "$STATE_DIR/prompts"; printf '%s' "$2" >"$STATE_DIR/prompts/$1.tmp" && mv "$STATE_DIR/prompts/$1.tmp" "$STATE_DIR/prompts/$1"
}
agent_state() { # agent_state <wt> <paneKey> → "state<TAB>updatedAt(秒)"。無ければ空
    jq -r --arg w "$1" --arg p "$2" '[.result.worktrees[] | select(.worktreeId == $w) | .agents[]? | select(.paneKey == $p)][0]
        // empty | [.state, (((.updatedAt // 0) / 1000) | floor | tostring)] | @tsv' <<<"$PS_JSON"
}

# ---- 着手直前の再確認 (GraphQL 1 回 + Orca の worktree) ----
# RC_CODE: ok | gone | pr-exists | owner | changed | error。RC_TITLE と RC_UPD を置く。
recheck_issue() { # recheck_issue <N> [自分の worktreeId]
    local n=$1 own=${2:--} json res others v
    # shellcheck disable=SC2016  # GraphQL の変数
    json=$(gh api graphql -F n="$n" -f owner="${REPO%%/*}" -f name="${REPO#*/}" -f query='
query($owner: String!, $name: String!, $n: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) { issue(number: $n) {
    state title updatedAt author { login }
    labels(first: 50) { pageInfo { hasNextPage } nodes { name } }
    assignees(first: 20) { pageInfo { hasNextPage } nodes { login } }
    closedByPullRequestsReferences(first: 20, includeClosedPrs: true) { pageInfo { hasNextPage } nodes { state } }
    timelineItems(itemTypes: [CROSS_REFERENCED_EVENT], first: 50) { pageInfo { hasNextPage }
      nodes { ... on CrossReferencedEvent { source { __typename ... on PullRequest { state } } } } }
  } }
}' 2>/dev/null) || { RC_CODE=error; return 0; }
    res=$(jq -r '.data.viewer.login as $me | .data.repository.issue as $i
        | if $i == null then "gone\t-\t-" else (
          if any($i.labels, $i.assignees, $i.closedByPullRequestsReferences, $i.timelineItems; .pageInfo.hasNextPage) then "error"
          elif $i.state != "OPEN" or ($i.author.login // "") != $me or any($i.labels.nodes[]; .name == "no-agent")
               or any($i.assignees.nodes[]; .login != $me) then "gone"
          elif any($i.closedByPullRequestsReferences.nodes[]; .state == "OPEN" or .state == "MERGED")
               or any($i.timelineItems.nodes[]; .source.__typename == "PullRequest" and (.source.state == "OPEN" or .source.state == "MERGED")) then "pr-exists"
          else "ok" end) + "\t" + $i.updatedAt + "\t" + ($i.title | gsub("[\t\n]"; " ")) end' <<<"$json" 2>/dev/null) || { RC_CODE=error; return 0; }
    IFS=$'\t' read -r RC_CODE RC_UPD RC_TITLE <<<"$res"
    [ "$RC_CODE" = "ok" ] || return 0
    orca_lists || { RC_CODE=error; return 0; } # 直前に取り直す (他のセッションや人が作った worktree)
    others=$(wt_for_issue "$n" | grep -vxF -- "$own" || true)
    [ -z "$others" ] || { RC_CODE=owner; return 0; }
    v=$(tsv_get "$VERDICTS" "$(key "$n")" | cut -f2)
    [ "$v" = "$RC_UPD" ] || { RC_CODE=changed; return 0; }
    RC_CODE=ok
}

# ---- 失敗と cooldown ----
fail_job() { # fail_job <N> <code> [補足]  (J_* は読み込み済み)
    local n=$1 code=$2 note=${3:-}
    J_STATUS=failed; J_NOTE="$code${note:+ $note}"; job_save
    event "$n" failed
    log "failed #$n: $J_NOTE"
    [ "$J_WT" != "-" ] && board "id:$J_WT" needs-decision "#$n $code${note:+ $(printf '%s' "$note" | cut -c1-60)}"
    cooldown_check
}
cooldown_check() { # 直近 1 時間に失敗 2 件なら 2 時間止める
    local recent until
    recent=$(awk -F'\t' -v t=$((NOW - 3600)) '$5 == "failed" && $2 > t' "$LAUNCHES" | wc -l | tr -d ' ')
    until=$(cfg cooldown_until)
    if [ "$recent" -ge 2 ] && ! { [ -n "$until" ] && [ "$until" -gt "$NOW" ]; }; then
        cfg_set cooldown_until $((NOW + 7200))
        log "直近 1 時間に失敗 $recent 件。cooldown を 2 時間"
    fi
}

# ---- sweep: Orca の結果で state を直すだけ。GitHub も起動も叩かない ----
sweep() {
    local n row st up
    board_retry
    for n in $(jobs_with launching running stalled); do
        job_load "$n"
        if [ "$J_STATUS" = "launching" ]; then
            if [ "$J_WT" = "-" ] && [ "$J_BRANCH" != "-" ]; then
                row=$(wt_by_branch "$J_BRANCH")
                [ -n "$row" ] && { IFS=$'\t' read -r J_WT J_BRANCH <<<"$row"; job_save; log "sweep #$n: worktree を拾った"; }
            fi
            if [ "$J_WT" != "-" ] && ! wt_exists "$J_WT"; then fail_job "$n" gone "起動途中に worktree 消失"; continue; fi
            if [ "$J_WT" != "-" ] && [ "$J_PANE" = "-" ]; then
                J_PANE=$(agent_for "$J_WT" "$n")
                if [ -n "$J_PANE" ]; then J_STATUS=running; job_save; event "$n" launched; log "sweep #$n: agent を拾った"; else J_PANE=-; fi
            fi
            continue
        fi
        if ! wt_exists "$J_WT"; then fail_job "$n" gone "worktree 消失"; continue; fi
        row=$(agent_state "$J_WT" "$J_PANE")
        if [ -z "$row" ]; then fail_job "$n" gone "agent 消失"; continue; fi
        IFS=$'\t' read -r st up <<<"$row"
        case "$st" in
            done | idle) fail_job "$n" no-pr "終了したが PR なし" ;;
            working)
                if [ "$J_STATUS" = "running" ] && { [ $((NOW - up)) -gt 7200 ] || [ $((NOW - J_START)) -gt 14400 ]; }; then
                    J_STATUS=stalled; job_save
                    board "id:$J_WT" needs-decision "停止: #$n $(((NOW - J_START) / 3600))h"
                fi ;;
            *) # waiting（権限確認など）や不明な状態: 枠は持ったまま人に回す
                if [ "$J_STATUS" = "running" ]; then
                    J_STATUS=stalled; job_save
                    board "id:$J_WT" needs-decision "入力待ち: #$n ($st)"
                fi ;;
        esac
    done
}

# ---- 起動 ----
slugify() {
    local s; s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-30 | sed 's/-$//')
    printf '%s' "${s:-work}"
}
# launch_agent <N> <prompt>: J_WT の worktree で worker を起動する。返事を失ったら operationId を残す。
launch_agent() {
    local n=$1 prompt=$2 out op exclude=${3:-}
    if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: agent launch #$n ($prompt)"; return 0; fi
    save_prompt "$n" "$prompt"
    local args=(agent launch --agent claude --worktree "id:$J_WT" --model opus --effort high --surface chat --prompt "$prompt" --json)
    case "$J_OP" in - | ok:*) ;; *) args+=(--retry-launch "$J_OP") ;; esac
    if out=$(orca "${args[@]}" 2>&1) && jq -e '.ok == true' <<<"$out" >/dev/null 2>&1; then
        J_OP="ok:$NOW"; J_NOTE="$(jq -r '.result.launch.outcome.kind // "?"' <<<"$out" 2>/dev/null || echo ?)"
        orca_lists || true
        J_PANE=$(agent_for "$J_WT" "$n" "$exclude" 2>/dev/null || true)
        if [ -n "$J_PANE" ]; then J_STATUS=running; else J_PANE=-; fi # 見えなければ sweep が拾う
        job_save; event "$n" launched
        log "launch #$n → $J_WT ($J_STATUS)"
    else
        op=$(jq -r '[.. | .operationId? // empty | strings][0] // empty' <<<"$out" 2>/dev/null || true)
        if [ -n "$op" ]; then J_OP=$op; J_NOTE="返事を失った。次の dispatch で --retry-launch"; fi
        [ -n "$op" ] || J_NOTE="起動に失敗: $(printf '%s' "$out" | tail -n 1 | cut -c1-80)"
        job_save
        log "WARN: launch #$n: $J_NOTE"
    fi
}
# 起動途中の job を進める (dispatch の最初、新規より先)
recover() {
    local n=$1 row
    if [ "$J_WT" = "-" ] && [ "$J_BRANCH" != "-" ]; then
        row=$(wt_by_branch "$J_BRANCH")
        [ -n "$row" ] && { IFS=$'\t' read -r J_WT J_BRANCH <<<"$row"; job_save; }
    fi
    if [ "$J_WT" = "-" ]; then
        J_STATUS=pending; J_BRANCH=-; J_OP=-; J_START=-; J_NOTE="worktree が作れなかった"; job_save
        event "$n" failed; log "recover #$n: worktree が無い。pending に戻す"; cooldown_check; return 0
    fi
    if ! wt_exists "$J_WT"; then fail_job "$n" gone "起動途中に worktree 消失"; return 0; fi
    J_PANE=$(agent_for "$J_WT" "$n")
    if [ -n "$J_PANE" ]; then J_STATUS=running; job_save; log "recover #$n: agent を拾った"; return 0; fi
    J_PANE=-
    case "$J_OP" in
        ok:*) [ $((NOW - ${J_OP#ok:})) -gt 1800 ] || return 0 # 起動は通った。agent が見えるまで待つ
              J_OP=- ;;
    esac
    # 起動から 1 時間経っても agent が見えなければ諦めて人に回す（枠を握り続けない）
    if [ "$J_START" != "-" ] && [ $((NOW - J_START)) -gt 3600 ]; then fail_job "$n" launch "1 時間起動できない"; return 0; fi
    launch_agent "$n" "$(cat "$STATE_DIR/prompts/$n" 2>/dev/null || echo "/issue-worker $n")"
}
launch_new() { # launch_new <N> (再確認済み。RC_TITLE がある)
    local n=$1 br out wt
    br="issue-$n-$(slugify "$RC_TITLE")"
    if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: launch #$n ($br)"; return 0; fi
    event "$n" reserved
    save_prompt "$n" "/issue-worker $n"
    J_STATUS=launching; J_BRANCH=$br; J_START=$NOW; J_NOTE=-; job_save
    local args=(worktree create --repo "path:$CHECKOUT" --name "$br" --branch "$br" --issue "$n" --base-branch "origin/$BASE" --setup run --json)
    [ -n "$DISPATCHER" ] && args+=(--parent-worktree "path:$DISPATCHER")
    out=$(orca "${args[@]}" 2>&1) || true
    wt=$(jq -r 'if .ok == true then .result.worktree.id // empty else empty end' <<<"$out" 2>/dev/null || true)
    if [ -z "$wt" ]; then
        J_NOTE="worktree create: $(printf '%s' "$out" | tail -n 1 | cut -c1-80)"; job_save
        log "WARN: #$n の worktree を作れない (次の dispatch で復旧)"; return 0
    fi
    J_WT=$wt; J_BRANCH=$(jq -r '.result.worktree.branch | sub("^refs/heads/"; "")' <<<"$out"); job_save
    orca worktree set --worktree "id:$wt" --display-name "$PREFIX: #$n ${RC_TITLE:0:30}" --json >/dev/null 2>&1 || true
    rm -f "$STATE_DIR/prompts/$n.exclude"
    launch_agent "$n" "/issue-worker $n"
}

# ---- サブコマンド ----
cmd_candidates() {
    load_cfg; lock
    log "candidates cwd=$PWD"
    orca status --json 2>/dev/null | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1 || { log "Orca に届かない。見送り"; exit 1; }
    orca_lists || { log "Orca の worktree を取れない。見送り"; exit 1; }
    sweep
    local me issues labels words run untriaged pending n upd title lbls asg v hit l w
    me=$(gh api user -q .login 2>/dev/null) || { log "gh が使えない。見送り"; exit 1; }
    issues=$(gh issue list -R "$REPO" --author @me --state open -L 500 --json number,title,labels,updatedAt,assignees 2>/dev/null) || { log "issue を取れない。見送り"; exit 1; }
    [ "$(jq length <<<"$issues")" -lt 500 ] || { log "issue が 500 件。打ち切りとみなして見送り"; exit 1; }
    jq -r '.[].number' <<<"$issues" >"$STATE_DIR/open.txt"
    labels=$(cfg ask_labels); words=$(cfg ask_title_words "$DEFAULT_TITLE_WORDS")
    untriaged=""
    while IFS=$'\t' read -r n upd title lbls asg; do
        [ -n "$n" ] || continue
        case ",$lbls," in *,no-agent,* | *,tracking,* | *,Stale,*) continue ;; esac
        [ "$asg" = "-" ] || ! printf '%s' "$asg" | tr ',' '\n' | grep -qvxF -- "$me" || continue
        [ -z "$(wt_for_issue "$n")" ] || continue
        [ -z "$(tsv_get "$JOBS" "$(key "$n")")" ] || continue
        v=$(tsv_get "$VERDICTS" "$(key "$n")" | cut -f2)
        [ "$v" != "$upd" ] || continue
        hit=""
        while IFS= read -r l; do [ -n "$l" ] && case ",$lbls," in *",$l,"*) hit="label $l" ;; esac; done < <(printf '%s\n' "$labels" | tr ',' '\n')
        if [ -z "$hit" ]; then
            while IFS= read -r w; do
                [ -n "$w" ] && [ -z "$hit" ] && printf '%s' "$title" | grep -qiF -- "$w" && hit="title $w"
            done < <(printf '%s\n' "$words" | tr ',' '\n')
        fi
        if [ -n "$hit" ]; then verdict_put "$n" "$upd" ask "$hit"; log "rule ask #$n: $hit"; continue; fi
        untriaged="$untriaged"untriaged$'\t'"$n"$'\t'"$upd"$'\t'"$title"$'\n'
    done < <(jq -r 'sort_by(.updatedAt) | reverse | .[] | [(.number | tostring), .updatedAt, (.title | gsub("[\t\n]"; " ")),
        ([.labels[].name] | join(",") | if . == "" then "-" else . end),
        ([.assignees[].login] | join(",") | if . == "" then "-" else . end)] | @tsv' <<<"$issues")
    pending=$(for n in $(jobs_with pending); do printf 'pending\t%s\n' "$n"; done
        for n in $(jobs_with launching); do printf 'launching\t%s\n' "$n"; done) # 復旧は dispatch が行うので run を止めない
    refresh_asks
    run="$STATE_DIR/runs/$NOW-$$"; mkdir -p "$run"
    printf '%s%s' "$untriaged" "${pending:+$pending$'\n'}" >"$run/candidates.tsv.tmp"
    mv "$run/candidates.tsv.tmp" "$run/candidates.tsv"
    printf '# repo=%s base=%s checkout=%s\n' "$REPO" "$BASE" "$CHECKOUT"
    cat "$run/candidates.tsv"
    [ -s "$run/candidates.tsv" ] || { log "候補なし"; exit 1; }
}

cmd_verdict() {
    local n=${1:?N} v=${2:?go|ask|skip} reason=${3:-} seen=${4:-} upd
    case "$v" in go | ask | skip) ;; *) die "verdict は go|ask|skip: $v" ;; esac
    load_cfg; lock
    upd=$(gh issue view "$n" -R "$REPO" --json updatedAt -q .updatedAt) || die "issue #$n を読めない"
    if [ -n "$seen" ] && [ "$seen" != "$upd" ]; then # 読んだ後に編集された。古い内容への判定は残さない
        log "verdict #$n: 読んだ版 ($seen) と今 ($upd) が違う。書かずに次回の再判定へ"; echo changed; exit 3
    fi
    verdict_put "$n" "$upd" "$v" "$reason"
    log "verdict #$n $v: $reason"
    if [ "$v" = "go" ]; then
        job_load "$n" || { job_new "$n"; job_save; }
    elif job_load "$n" && [ "$J_STATUS" = "pending" ]; then
        tsv_del "$JOBS" "$J_KEY"
    fi
    refresh_asks
}

cmd_dispatch() {
    load_cfg; lock
    dispatch_allowed || exit 0
    orca_lists || { log "Orca の worktree を取れない。見送り"; exit 0; }
    RUN_ID="d$NOW-$$"
    local n launched=0 active today
    for n in $(jobs_with launching); do
        dispatch_allowed || exit 0 # 復旧中の失敗で cooldown に入ったら残りも起動しない
        job_load "$n"; recover "$n"
    done
    for n in $(jobs_with pending); do
        dispatch_allowed || break
        active=$(jobs_with launching running stalled | grep -c . || true)
        today=$(awk -F'\t' -v d="$TODAY" '$3 == d && $5 == "reserved"' "$LAUNCHES" | wc -l | tr -d ' ')
        if [ "$launched" -ge "$(cfg max_per_run 2)" ] || [ "$active" -ge "$(cfg max_active 3)" ] || [ "$today" -ge "$(cfg max_per_day 4)" ]; then
            log "上限 (今回 $launched / 稼働 $active / 今日 $today)。残りは次回"; break
        fi
        job_load "$n"
        recheck_issue "$n"
        [ "$RC_CODE" != "ok" ] || [ "$(tsv_get "$VERDICTS" "$J_KEY" | cut -f3)" = "go" ] || RC_CODE=not-go
        case "$RC_CODE" in
            ok) launch_new "$n"; launched=$((launched + 1)) ;;
            gone) tsv_del "$JOBS" "$J_KEY"; verdict_put "$n" "${RC_UPD:--}" skip "recheck: closed か対象外"; log "recheck #$n: gone" ;;
            pr-exists | owner) tsv_del "$JOBS" "$J_KEY"; verdict_put "$n" "${RC_UPD:--}" ask "$RC_CODE"; log "recheck #$n: $RC_CODE" ;;
            not-go) tsv_del "$JOBS" "$J_KEY"; log "dispatch #$n: 判定が go でない。起動しない" ;;
            changed) tsv_del "$JOBS" "$J_KEY"; tsv_del "$VERDICTS" "$J_KEY"; log "recheck #$n: issue が編集された。再判定へ" ;;
            *) log "recheck #$n: 確かめられない。今回は飛ばす" ;;
        esac
    done
    refresh_asks
}

cmd_resume() {
    local n=${1:?N} instr=${2:?指示} prompt old
    load_cfg; lock
    dispatch_allowed || exit 1
    job_load "$n" || die "#$n の job が無い"
    case "$J_STATUS" in stalled | failed) ;; *) die "#$n は $J_STATUS。resume できるのは stalled か failed" ;; esac
    [ "$J_WT" != "-" ] || die "#$n に worktree が無い"
    orca_lists || die "Orca の worktree を取れない"
    wt_exists "$J_WT" || die "#$n の worktree が消えている"
    ! agent_alive "$J_WT" "$J_PANE" || die "#$n の agent ($J_PANE) はまだ残っている。タブを閉じてから resume する"
    if [ "$J_STATUS" = "failed" ] && [ "$(jobs_with launching running stalled | grep -c . || true)" -ge "$(cfg max_active 3)" ]; then
        die "稼働が上限 ($(cfg max_active 3))。空いてから resume する" # stalled は枠を持ったままなので数えない
    fi
    prompt="/issue-worker $n --resume '$(printf '%s' "$instr" | tr "'\n" "’ ")'"
    old=$J_PANE; RUN_ID="r$NOW-$$"
    if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN: resume #$n ($prompt)"; return 0; fi
    mkdir -p "$STATE_DIR/prompts"; printf '%s\n' "$old" >>"$STATE_DIR/prompts/$n.exclude" # 過去の pane は全部除く
    save_prompt "$n" "$prompt"
    J_STATUS=launching; J_PANE=-; J_OP=-; J_START=$NOW; job_save # 4 時間の通知は再開から数える
    board "id:$J_WT" in-progress "再開: #$n"
    launch_agent "$n" "$prompt" "$old"
}

cmd_recheck() {
    local n=${1:?N} own=-
    load_cfg; touch "$VERDICTS" "$JOBS" 2>/dev/null || true
    job_load "$n" && own=$J_WT
    recheck_issue "$n" "$own"
    echo "$RC_CODE"
}

cmd_done() {
    local n=${1:?N} url=${2:?pr-url}
    load_cfg; lock
    job_load "$n" || die "#$n の job が無い"
    J_STATUS=pr_opened; J_PR=$url; J_NOTE=-; job_save
    if [ "$J_WT" != "-" ]; then board "id:$J_WT" in-review "PR #${url##*/}"; fi # 判断待ちのままだと pr-dispatch が触らない
    log "done #$n: $url"
}

cmd_fail() {
    local n=${1:?N} code=${2:?code}
    shift 2
    load_cfg; lock
    job_load "$n" || die "#$n の job が無い"
    fail_job "$n" "$code" "$*"
}

cmd_go() {
    local n=${1:?N}
    load_cfg; lock
    if job_load "$n" && [ "$J_STATUS" != "pending" ]; then die "#$n は起動済み ($J_STATUS)。続きは resume"; fi
    cmd_verdict "$n" go "人が go"
}

cmd_skip() {
    local n=${1:?N}
    load_cfg; lock
    if job_load "$n"; then
        case "$J_STATUS" in
            pending) tsv_del "$JOBS" "$J_KEY" ;;
            launching) die "#$n は起動中。running になってからタブを閉じ、もう一度 skip する" ;;
            running | stalled)
                orca_lists || die "Orca の worktree を取れない"
                ! agent_alive "$J_WT" "$J_PANE" || die "#$n の agent ($J_PANE) はまだ残っている。タブを閉じてから skip する"
                J_STATUS=failed; J_NOTE="人が skip"; job_save ;;
        esac
    fi
    cmd_verdict "$n" skip "人が skip"
}

cmd_status() {
    load_cfg; touch "$JOBS" "$LAUNCHES" 2>/dev/null || true
    echo "repo=$REPO checkout=$CHECKOUT base=$BASE dispatcher=${DISPATCHER:--}"
    echo "dispatch_enabled=$(cfg dispatch_enabled) cooldown_until=$(cfg cooldown_until) max_per_run=$(cfg max_per_run 2) max_active=$(cfg max_active 3) max_per_day=$(cfg max_per_day 4)"
    echo "今日の起動 $(awk -F'\t' -v d="$TODAY" '$3 == d && $5 == "reserved"' "$LAUNCHES" | wc -l | tr -d ' ') / 稼働 $(jobs_with launching running stalled | grep -c . || true)"
    echo "--- jobs (key status branch worktreeId operationId paneKey prUrl started updated note)"
    cat "$JOBS"
}

cmd_register() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$CONFIG" ]; then
        cat >"$CONFIG" <<EOF
repo=
checkout=
base=main
dispatcher_worktree=
card_prefix=
ask_labels=
ask_title_words=$DEFAULT_TITLE_WORDS
dispatch_enabled=false
max_per_run=2
max_active=3
max_per_day=4
cooldown_until=
EOF
        echo "雛形を置いた: $CONFIG (repo・checkout・dispatcher_worktree を埋めて再実行)"; exit 0
    fi
    load_cfg
    [ -n "$DISPATCHER" ] || die "config に dispatcher_worktree が要る"
    local id args
    id=$(orca automations list --json | jq -r '[.result.automations[] | select(.name == "issue-autopilot") | .id][0] // empty')
    args=(--trigger "0 */2 * * *" --timezone Asia/Tokyo --provider claude
        --workspace "path:$DISPATCHER" --workspace-mode existing
        --extra-agent-args="--model sonnet --effort medium"
        --precheck "$SELF candidates" --precheck-timeout 120
        --prompt "/issue-autopilot" --json)
    if [ -n "$id" ]; then
        orca automations edit --id "$id" "${args[@]}" | jq -c '.result.automation | {id, enabled}'
    else
        id=$(orca automations create --name issue-autopilot "${args[@]}" --disabled | jq -r '.result.automation.id')
        echo "created $id (disabled)"
    fi
    printf '%s\n' "$id" >"$STATE_DIR/automation_id"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
    candidates | verdict | dispatch | resume | recheck | done | fail | go | skip | status | register) "cmd_$cmd" "$@" ;;
    *) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
