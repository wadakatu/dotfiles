#!/bin/bash
# 放置された Claude / Codex のセッションを見つけて知らせ、ユーザーが確かめたものだけを
# Orca の端末に /exit を送って終わらせる。KILL はしない。設計は docs/agent-gc-design.md。
#   agent-gc.sh scan              launchd が 10 分ごとに回す。新しい候補があれば通知する
#   agent-gc list                 候補と残した理由を一覧にし、listed.tsv に書く
#   agent-gc stop <pid>...        判定し直し、入力欄が空なら /exit を送る (DRY_RUN=1 で表示だけ)
#   agent-gc stop --listed        最後に list で見せた候補を止める
#   agent-gc.sh judge             stdin の JSON 行に reason を足す (テスト用、macOS のコマンドを呼ばない)
#   agent-gc.sh prompt-empty <a>  stdin の端末の末尾で、入力欄が空なら 0 を返す (テスト用)
set -u
export LC_ALL=C

IDLE_H=${IDLE_H:-24}           # この時間 idle なら候補
IDLE_WARN_H=${IDLE_WARN_H:-6}  # memory pressure が WARN 以上のときの閾値
EXCLUDE_RE=${EXCLUDE_RE:-}     # 候補にしないパスの正規表現
STATE_DIR=${STATE_DIR:-"$HOME/Library/Application Support/agent-gc"}
LOG=${LOG:-"$HOME/Library/Logs/agent-gc.log"}

# ログに書き、端末から打ったときは画面にも出す。
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$line" >>"$LOG"
    [ -t 1 ] && echo "$line"
    return 0
}

notify() {
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "agent-gc"' -e 'end run' "$*" >/dev/null 2>&1 || true
}

# 3.2 の表。値が欠けたら、どの段でも keep に倒れる。
judge() {
    jq -c --argjson idle_h "$IDLE_H" --argjson warn_h "$IDLE_WARN_H" --arg exclude "$EXCLUDE_RE" '
        (if (.pressure // 0) >= 2 then $warn_h else $idle_h end) as $th
        | [.orca.sub_states[]? | select(. != "done" and . != "idle")] as $sub
        | .reason = (
            if .readable != true then "unreadable"
            elif .status != "idle" then "status=\(.status)"
            elif (.idle_sec | type) != "number" or .idle_sec < $th * 3600 then "idle \((.idle_sec // 0) / 3600 | floor)h"
            elif .orca.ok != true then "orca-unreachable"
            elif .orca.found != true then "not-in-orca"
            elif .orca.state != "done" then "orca \(.orca.state)"
            elif ($sub | length) > 0 then "orca-sub \($sub[0])"
            elif (.orca.workspace_status | type) != "string" then "orca-incomplete"
            elif .orca.workspace_status == "needs-decision" then "needs-decision"
            elif $exclude != "" and ((.path // "") | test($exclude)) then "excluded"
            else null end)'
}

# 端末の末尾 (1 行 1 要素の文字列) から、入力欄が空かを見る。書きかけに /exit を足して送らないため。
prompt_empty() {
    local agent=$1 line
    case $agent in
        # 最後の ❯ の行が ❯ だけで、次の行が入力欄の下の罫線であること。複数行の書きかけは 2 行目以降に出る。
        claude) awk '/^❯/ { p = $0; n = ""; getline n; last = p "\n" n } END { exit !(last ~ /^❯[[:space:]]*\n─/) }' ;;
        # 空の入力欄には placeholder が出る。書きかけと文字では見分けられないので、この文言だけを空とみなす。
        codex) line=$(grep '^› ' | tail -1) && [ "$(printf '%s' "$line" | sed 's/[[:space:]]*$//')" = "› Ask Codex to do anything" ] ;;
        *) return 1 ;;
    esac
}

# ps eww の出力から環境変数を 1 つ取り出す。引数にも同じ文字列が出るので、前が空白のものの最後を使う。
env_of() { grep -oE " $2=[^ ]*" <<<"$1" | tail -1 | sed "s/^ $2=//"; }

lstart_of() { TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//; s/  */ /g'; }

# Codex の rollout から状態を出す: "idle <最後の task_complete の秒>" / "busy" / 空 (読めない)
codex_state() {
    local pid=$1 f last max=0 n=0 ts
    while IFS= read -r f; do
        [ -f "$f" ] || return 0
        # 書きかけの行があれば、今も書いている
        [ "$(tail -c1 "$f" | od -An -c | tr -d ' ')" = '\n' ] || { echo busy; return 0; }
        last=$(tail -n 200 "$f" | jq -r -R 'fromjson? | select(.type == "event_msg") | "\(.payload.type)\t\(.timestamp)"' | tail -1)
        [ -n "$last" ] || return 0
        [ "${last%%$'\t'*}" = task_complete ] || { echo busy; return 0; }
        ts=$(jq -rn --arg t "${last#*$'\t'}" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601') || return 0
        [ "$ts" -gt "$max" ] && max=$ts
        n=$((n + 1))
    done < <(lsof -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | grep '/\.codex/sessions/.*/rollout-.*\.jsonl$')
    [ "$n" -gt 0 ] && echo "idle $max"
}

# 1 セッション 1 行の JSON を出す。pid を渡せばその 1 本だけ。macOS 専用。
collect() {
    local only=${1:-}
    local now pressure orca_json orca_ok pid comm envs lstart pane term wt f readable status ts path key st
    now=$(date +%s)
    pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)
    orca_ok=false
    if orca_json=$(orca worktree ps --json 2>/dev/null) &&
        jq -e '.result.truncated == false and ((.result.hostScope.omittedHostIds // []) | length) == 0' <<<"$orca_json" >/dev/null 2>&1; then
        orca_ok=true
    else
        orca_json='{}'
    fi

    ps -axo pid=,comm= | awk -v only="$only" '($2 == "claude" || $2 == "codex") && (only == "" || $1 == only) { print $1, $2 }' | while read -r pid comm; do
        envs=$(ps eww -o command= -p "$pid" 2>/dev/null) || continue
        lstart=$(lstart_of "$pid")
        pane=$(env_of "$envs" ORCA_PANE_KEY)
        term=$(env_of "$envs" ORCA_TERMINAL_HANDLE)
        wt=$(env_of "$envs" ORCA_WORKTREE_ID)
        readable=false status="" ts="" path=""
        if [ "$comm" = claude ]; then
            f="$HOME/.claude/sessions/$pid.json"
            if [ -f "$f" ]; then
                # claude -p などは対象外
                [ "$(jq -r '.kind // empty' "$f" 2>/dev/null)" = interactive ] || continue
                if jq -e --argjson pid "$pid" --arg ls "$lstart" '
                    .pid == $pid and (.procStart | gsub(" +"; " ")) == $ls and (.status | type) == "string"
                    and ((.statusUpdatedAt // .updatedAt) | type) == "number"' "$f" >/dev/null 2>&1; then
                    readable=true
                    status=$(jq -r .status "$f")
                    ts=$(jq -r '(.statusUpdatedAt // .updatedAt) / 1000 | floor' "$f")
                    path=$(jq -r '.cwd // ""' "$f")
                fi
            fi
        else
            st=$(codex_state "$pid")
            case $st in
                idle\ *) readable=true status=idle ts=${st#idle } ;;
                busy) readable=true status=busy ts=$now ;;
            esac
            path=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        fi
        key="$pid:${lstart// /_}:$ts"
        jq -cn --argjson pid "$pid" --arg agent "$comm" --arg lstart "$lstart" --arg key "$key" \
            --argjson readable "$readable" --arg status "$status" --arg ts "$ts" --argjson now "$now" \
            --argjson pressure "$pressure" --arg path "$path" --arg term "$term" --arg wt "$wt" \
            --arg pane "$pane" --argjson orca_ok "$orca_ok" --argjson o "$orca_json" '
            ([$o.result.worktrees[]? as $w | $w.agents[]? | select($pane != "" and .paneKey == $pane)
              | {state, workspace_status: $w.workspaceStatus}] | first) as $a
            | {pid: $pid, agent: $agent, lstart: $lstart, key: $key, readable: $readable,
               status: $status, idle_sec: (if $ts == "" then null else $now - ($ts | tonumber) end),
               pressure: $pressure, path: $path, term: $term, worktree: $wt,
               orca: {ok: $orca_ok, found: ($a != null), state: $a.state, workspace_status: $a.workspace_status,
                      sub_states: [$o.result.worktrees[]?.agents[]? | select($pane != "" and .parentPaneKey == $pane) | .state]}}'
    done
}

scan() {
    local rows cands n new seen alive
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/notified.tsv"
    rows=$(collect | judge)
    cands=$(jq -r 'select(.reason == null) | .key' <<<"$rows")
    n=$(grep -c . <<<"$cands")
    new=$(grep -vxF -f "$STATE_DIR/notified.tsv" <<<"$cands" | grep -c .)
    # 鍵はプロセスが終わるまで残す。一時的に候補から外れても、同じ放置を 2 回知らせない。
    alive=$(jq -r '.key | split(":")[:2] | join(":")' <<<"$rows")
    seen=$({ cat "$STATE_DIR/notified.tsv"; printf '%s\n' "$cands"; } | grep . | sort -u |
        while IFS= read -r k; do grep -qxF "$(cut -d: -f1-2 <<<"$k")" <<<"$alive" && echo "$k"; done)
    printf '%s\n' "$seen" | grep . >"$STATE_DIR/notified.tsv"
    [ "$new" -gt 0 ] && notify "止める候補 $n 本（新規 $new）。agent-gc list で確かめて agent-gc stop --listed"

    # 記録の形式が変わって 1 本も読めなくなったら、その日 1 回だけ知らせる
    if jq -e -s 'map(select(.agent == "claude")) | length > 0 and all(.readable == false)' <<<"$rows" >/dev/null &&
        [ "$(cat "$STATE_DIR/format-warned" 2>/dev/null)" != "$(date +%F)" ]; then
        log "WARN: claude のプロセスはあるが ~/.claude/sessions を 1 本も読めない"
        notify "~/.claude/sessions を読めません。形式が変わった可能性があります"
        date +%F >"$STATE_DIR/format-warned"
    fi
    log "scan pressure=$(jq -rs '.[0].pressure // "-"' <<<"$rows") sessions=$(grep -c . <<<"$rows")" \
        "candidates=$n new=$new unreadable=$(jq -s 'map(select(.reason == "unreadable")) | length' <<<"$rows")"
}

list() {
    local rows
    mkdir -p "$STATE_DIR"
    rows=$(collect | judge)
    jq -r 'select(.reason == null) | "\(.pid)\t\(.key)"' <<<"$rows" >"$STATE_DIR/listed.tsv"
    jq -rs '
        def h: if .idle_sec == null then "-" else "\(.idle_sec / 3600 | floor)h" end;
        (map(select(.reason == null)) | sort_by(-.idle_sec)) as $c
        | "候補 \($c | length) 本 (agent-gc stop --listed で止める)",
          ($c[] | "  \(.pid)\t\(.agent)\t\(h)\t\(.path)"),
          "", "残すもの",
          (map(select(.reason != null)) | sort_by(.reason)[] | "  \(.pid)\t\(.agent)\t\(h)\t\(.reason)\t\(.path)")
    ' <<<"$rows"
}

stop() {
    local targets rows row pid want reason term agent terms
    if [ "${1:-}" = --listed ]; then
        targets=$(cat "$STATE_DIR/listed.tsv" 2>/dev/null)
        [ -n "$targets" ] || { echo "listed.tsv が空です。先に agent-gc list を打ってください" >&2; return 1; }
    else
        [ $# -gt 0 ] || { echo "usage: agent-gc stop <pid>... | --listed" >&2; return 1; }
        targets=$(printf '%s\t\n' "$@")
    fi
    while IFS=$'\t' read -r pid want; do
        [ -n "$pid" ] || continue
        # 前の 1 本の終了待ちの間に再開されることがあるので、送る直前に 1 本ずつ取り直す
        [[ "$pid" =~ ^[0-9]+$ ]] || { log "skip pid=$pid: not a pid"; continue; }
        row=$(collect "$pid" | judge)
        terms=$(orca terminal list --json 2>/dev/null)
        agent=$(jq -r '.agent // "?"' <<<"$row" 2>/dev/null)
        if [ -z "$row" ]; then log "skip pid=$pid: not running"; continue; fi
        reason=$(jq -r '.reason // empty' <<<"$row")
        if [ -n "$reason" ]; then log "skip $agent pid=$pid: $reason"; continue; fi
        if [ -n "$want" ] && [ "$want" != "$(jq -r .key <<<"$row")" ]; then log "skip $agent pid=$pid: changed since list"; continue; fi
        term=$(jq -r .term <<<"$row")
        # agentIdentity は時々 null で返る (実測)。別のエージェントと出たときだけ止めない。入力欄は画面で確かめる。
        if [ -z "$term" ] || ! jq -e --arg h "$term" --arg a "$agent" \
            'any(.result.terminals[]?; .handle == $h and (.agentIdentity == null or .agentIdentity == $a))' <<<"$terms" >/dev/null 2>&1; then
            log "skip $agent pid=$pid: Orca の端末が見つからない"; continue
        fi
        # 既定の read は出力の履歴なので、差分で描いた書きかけを見落とす。今の描画 (--screen) で見る。
        # draft は Orca の入力欄に書きかけの文字。あれば使うつもりなので止めない。
        if ! orca terminal read --terminal "$term" --screen --json 2>/dev/null |
            jq -r '.result.terminal | if .source == "screen" and ((.draft // "") == "") then .tail[] else empty end' |
            prompt_empty "$agent"; then
            log "skip $agent pid=$pid: input not empty"; continue
        fi
        if [ "${DRY_RUN:-0}" = 1 ]; then echo "would stop $agent pid=$pid $(jq -r .path <<<"$row")"; continue; fi
        orca terminal send --terminal "$term" --text /exit --enter --json >/dev/null 2>&1 || { log "failed $agent pid=$pid: send"; continue; }
        local lstart i
        lstart=$(jq -r .lstart <<<"$row")
        for i in $(seq 20); do
            [ "$(lstart_of "$pid")" = "$lstart" ] || break
            sleep 1
        done
        if [ "$(lstart_of "$pid")" = "$lstart" ]; then
            log "failed $agent pid=$pid: still running after /exit"
        else
            log "stopped $agent pid=$pid idle=$(jq -r '.idle_sec / 3600 | floor' <<<"$row")h path=$(jq -r .path <<<"$row")"
        fi
    done <<<"$targets"
}

case "${1:-}" in
    scan) scan ;;
    list) list ;;
    stop) shift; stop "$@" ;;
    judge) judge ;;
    prompt-empty) prompt_empty "${2:-}" ;;
    *) echo "usage: agent-gc {scan|list|stop <pid>...|stop --listed}" >&2; exit 2 ;;
esac
