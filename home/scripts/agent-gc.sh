#!/bin/bash
# 放置された Claude / Codex のセッションを見つけて知らせ、ユーザーが確かめたものだけを
# Orca の端末に /exit を送って終わらせる。KILL はしない。設計は docs/agent-gc-design.md。
#   agent-gc.sh scan --auto       launchd が 10 分ごとに origin/main の写しで回す。新しい候補があれば通知する
#                                 (--auto は巡回の印。今は読まず、scan と同じに動く)
#   agent-gc list                 候補と残した理由を一覧にし、listed.tsv に書く
#   agent-gc stop <pid>...        判定し直し、入力欄が空なら /exit を送る (DRY_RUN=1 で表示だけ)
#   agent-gc stop --listed        最後に list で見せた候補を止める
#   agent-gc.sh judge             stdin の JSON 行に reason を足す (テスト用、macOS のコマンドを呼ばない)
#   agent-gc.sh prompt-empty <a>  stdin の端末の末尾で、入力欄が空なら 0 を返す (テスト用)
set -u
export LC_ALL=C

IDLE_H=${IDLE_H:-24}           # この時間 idle なら候補
IDLE_WARN_H=${IDLE_WARN_H:-6}  # memory pressure が WARN 以上のときの閾値
EXCLUDE_RE=${EXCLUDE_RE:-}     # 候補にしないパスの正規表現 (「触らない」リストとどちらかに当たれば候補にしない)
# 状態の根は cleanup-ledger.sh と同じ STATE_ROOT。テストはこの 1 つを一時ディレクトリに向ける。
STATE_DIR=${STATE_DIR:-"${STATE_ROOT:-$HOME/Library/Application Support}/agent-gc"}
LOG=${LOG:-"$HOME/Library/Logs/agent-gc.log"}
CLAUDE_SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
CLAUDE_PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"

# 止めたものの台帳と「触らない」リストは、掃除ジョブの共有ファイル cleanup-ledger.sh から読む。
# ~/.local/bin/agent-gc は nix の store を挟んだ symlink の連なりでこのファイルを指すので、BASH_SOURCE の
# dirname では home/scripts に届かない。readlink -f は古い macOS に無いので 1 段ずつ辿る (相対のリンクは
# リンクの在る場所から)。回数の上限は、輪になったリンクで回り続けないため。
self=${BASH_SOURCE[0]}
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -L "$self" ] || break
    link=$(readlink "$self")
    case $link in
        /*) self=$link ;;
        *) self=$(dirname "$self")/$link ;;
    esac
done
# 読めなくても scan と list は今どおり動かす (止めないので要らない)。stop は入口で 1 本も止めずに終わる。
# 「触らない」リストの行が cwd の中を指すとき (祖先の一致) は守らない。worktree-gc は対象を消すと中身も消えるので
# 守るが、セッションを止めても中身は消えない。当てると ~/www の下に 1 行あるだけで ~ や ~/www のセッションが止まらなくなる。
ledger_ok=0
# shellcheck source=home/scripts/cleanup-ledger.sh
if [ -r "$(dirname "$self")/cleanup-ledger.sh" ] && . "$(dirname "$self")/cleanup-ledger.sh"; then ledger_ok=1 keep_ancestors=0; fi

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
        | .threshold_h = $th
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
            elif .bg_shell == true then "bg-shell"
            elif .bg_shell != false then "bg-unknown"
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
    local now pressure orca_json orca_ok pid comm bg envs lstart pane term wt f readable status ts path key st sid
    now=$(date +%s)
    pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0)
    orca_ok=false
    if orca_json=$(orca worktree ps --json 2>/dev/null) &&
        jq -e '.result.truncated == false and ((.result.hostScope.omittedHostIds // []) | length) == 0' <<<"$orca_json" >/dev/null 2>&1; then
        orca_ok=true
    else
        orca_json='{}'
    fi

    # プロセスの一覧は 1 回だけ取り、セッションごとに子孫を辿る。子孫にシェルが居れば、ターンを終えた後も
    # 裏のコマンドが走っている (止めると resume で戻らない)。コマンド名は空白を含みうるので 3 列目から行末まで取り、
    # 先頭の - (ログインシェル) とディレクトリを落として比べる (zsh・bash・sh・fish・dash・ksh)。タブのシェルは祖先なので数えない。
    # ponytail: MCP のサーバをシェルのスクリプトで包んで起動している環境では、全部のセッションが bg-shell で残る
    # (agent-gc list の「残すもの」に出る)。そうなったら、除く名前を設定で渡す。
    ps -axo pid=,ppid=,comm= | awk -v only="$only" '
        match($0, /^ *[0-9]+ +[0-9]+ /) {
            split(substr($0, 1, RLENGTH), f, " ")
            comm = substr($0, RLENGTH + 1)
            n++; P[n] = f[1]; C[n] = comm; kids[f[2]] = kids[f[2]] " " f[1]
            name = comm; sub(/^-/, "", name); sub(/.*\//, "", name)
            if (name == "zsh" || name == "bash" || name == "sh" || name == "fish" || name == "dash" || name == "ksh") shell[f[1]] = 1
        }
        END {
            for (i = 1; i <= n; i++) {
                if ((C[i] != "claude" && C[i] != "codex") || (only != "" && P[i] != only)) continue
                bg = "false"; q = P[i]; split("", seen); seen[P[i]] = 1
                while (q != "" && bg == "false") {
                    m = split(q, cur, " "); q = ""
                    for (j = 1; j <= m; j++) {
                        k = split(kids[cur[j]], ch, " ")
                        for (l = 1; l <= k; l++) {
                            if (ch[l] in seen) continue
                            seen[ch[l]] = 1; q = q " " ch[l]
                            if (ch[l] in shell) bg = "true"
                        }
                    }
                }
                print P[i], C[i], bg
            }
        }' | while read -r pid comm bg; do
        envs=$(ps eww -o command= -p "$pid" 2>/dev/null) || continue
        lstart=$(lstart_of "$pid")
        pane=$(env_of "$envs" ORCA_PANE_KEY)
        term=$(env_of "$envs" ORCA_TERMINAL_HANDLE)
        wt=$(env_of "$envs" ORCA_WORKTREE_ID)
        readable=false status="" ts="" path="" sid=""
        if [ "$comm" = claude ]; then
            f="$CLAUDE_SESSIONS/$pid.json"
            if [ -f "$f" ]; then
                # claude -p などは対象外
                # 読めて非対話と分かったものだけ外す。読めないものは unreadable として残し、形式の警告に数える。
                jq -e '(.kind | type) == "string" and .kind != "interactive"' "$f" >/dev/null 2>&1 && continue
                if jq -e --argjson pid "$pid" --arg ls "$lstart" '
                    .pid == $pid and (.procStart | gsub(" +"; " ")) == $ls and (.status | type) == "string"
                    and ((.statusUpdatedAt // .updatedAt) | type) == "number"' "$f" >/dev/null 2>&1; then
                    readable=true
                    status=$(jq -r .status "$f")
                    ts=$(jq -r '(.statusUpdatedAt // .updatedAt) / 1000 | floor' "$f")
                    path=$(jq -r '.cwd // ""' "$f")
                    # 再開の ID。この記録は終了で消えるので、/exit を送る前のここで控える (stop は判定し直すたびにここを通る)。
                    sid=$(jq -r '.sessionId // "" | strings' "$f")
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
            --arg pane "$pane" --argjson orca_ok "$orca_ok" --argjson o "$orca_json" --arg sid "$sid" --arg bg "$bg" '
            ([$o.result.worktrees[]? as $w | $w.agents[]? | select($pane != "" and .paneKey == $pane)
              | {state, workspace_status: $w.workspaceStatus}] | first) as $a
            | {pid: $pid, agent: $agent, lstart: $lstart, key: $key, readable: $readable, sid: $sid,
               status: $status, idle_sec: (if $ts == "" then null else $now - ($ts | tonumber) end),
               pressure: $pressure, path: $path, term: $term, worktree: $wt,
               bg_shell: (if $bg == "true" then true elif $bg == "false" then false else null end),
               orca: {ok: $orca_ok, found: ($a != null), state: $a.state, workspace_status: $a.workspace_status,
                      sub_states: [$o.result.worktrees[]?.agents[]? | select($pane != "" and .parentPaneKey == $pane) | .state]}}'
    done
}

# judge の後ろの 1 段。候補の Claude のうち、会話記録に予約を作る呼び出し (CronCreate・ScheduleWakeup の tool_use) が
# 在るものを scheduled、会話記録が引けないものを sched-unknown にする (どちらも keep)。未発火の予約は記録の status に
# 出ず、止めると自分で間隔を決める /loop は戻らない。jq だけの judge に置かないのは、ファイルを読むため。
# 道具の名前は道具の一覧や本文にも出るので、文字列の一致では決めない。数十 MB になるので grep で行を絞り、
# 当たった行を jq で tool_use の要素か確かめる。当たった行が JSON として読めなければ、分からないとして残す。
# ponytail: 済んだ予約・消した予約でも残る。未発火だけを見分けるなら、CronDelete と発火を突き合わせる。
sched() {
    local row sid f got ok err
    while IFS= read -r row; do
        # 「確かめなくてよい」と「jq が動かなかった」を分けるため、終了コードでなく出力の文字で見る。
        # sched-unknown を付ける jq も失敗したら行が消える (候補にならない。stop では not running で送らない)。
        case $(jq -r 'if .agent == "claude" and .reason == null then "check" else "pass" end' <<<"$row" 2>/dev/null) in
            pass) printf '%s\n' "$row"; continue ;;
            check) ;;
            *) jq -c '.reason = "sched-unknown"' <<<"$row"; continue ;;
        esac
        sid=$(jq -r '.sid // ""' <<<"$row")
        got="" ok=0 err=0
        # ID は glob に入れるので、ID の形でないもの (空も) は引かない。
        case $sid in
            '' | *[!A-Za-z0-9_-]*) ;;
            *)
                # 退避された写し (<ID>.* の別名) も読む。
                for f in "$CLAUDE_PROJECTS"/*/"$sid".*; do
                    [ -f "$f" ] || continue
                    # "<0 予約なし / 1 読めない行 / 2 予約あり> <grep の終了コード> <jq の終了コード>"。grep は 1 が当たらない、2 が読めない。
                    # -a: NUL を含む会話記録でも行を出す (GNU grep は行の代わりに binary file matches を出す)。
                    got=$(grep -a -h -F -e CronCreate -e ScheduleWakeup -- "$f" 2>/dev/null |
                        jq -njR 'reduce (inputs | try (fromjson
                                | if any(.. | objects; .type == "tool_use" and (.name == "CronCreate" or .name == "ScheduleWakeup"))
                                  then 2 else 0 end) catch 1) as $s (0; if $s > . then $s else . end)' 2>/dev/null
                        printf ' %s %s' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}")
                    case $got in
                        "2 "[01]" 0") got=scheduled; break ;;
                        "0 "[01]" 0") ok=1 ;;
                        *) err=1 ;;
                    esac
                done
                ;;
        esac
        if [ "$got" = scheduled ]; then
            jq -c '.reason = "scheduled"' <<<"$row"
        elif [ "$ok" = 1 ] && [ "$err" = 0 ]; then
            printf '%s\n' "$row"
        else
            jq -c '.reason = "sched-unknown"' <<<"$row"
        fi
    done
}

scan() {
    local rows cands n new seen alive
    mkdir -p "$STATE_DIR"
    touch "$STATE_DIR/notified.tsv"
    rows=$(collect | judge | sched)
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
        "candidates=$n new=$new unreadable=$(jq -s 'map(select(.reason == "unreadable")) | length' <<<"$rows")" \
        "sched_unknown=$(jq -s 'map(select(.reason == "sched-unknown")) | length' <<<"$rows")"
}

list() {
    local rows
    mkdir -p "$STATE_DIR"
    rows=$(collect | judge | sched)
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

# 起動時のコマンドライン (ps の 1 行) から、再開に付けてよい引数 (--plugin-dir・--model・--effort) だけを
# printf %q で引用して出す。位置引数の指示 (/some-command <URL>) や --prefill を付けると、再開したときに
# 次のターンとして実行されるので、起動時の引数をそのまま付けない。
# ps は argv の境界を残さない (空白で繋いだ 1 行) ので、空白で割ってから値を組み直す。
#   --plugin-dir: 値に空白が入りうる (~/Library/Application Support/...)。続くトークンを足していき、
#                 実在するディレクトリになる最長のものを値にする。どれも当たらなければ付けない。
#   --model・--effort: 値は 1 トークン。--flag=値 の形も読む。
#   --model・--effort の値が空か - で始まるときは、値が欠けているので flag ごと付けない。
#   --resume・-r: 値 (ID) ごと読み飛ばす。台帳の戻し方で再開したセッションを次に止めるとき、ID を位置引数と
#                 みなして止まると、許可した引数が落ちる。次のトークンが - で始まるときは値とみなさない。
# 走査は、許可した flag の値でも - で始まるのでもない最初のトークン (位置引数の始まり) で止める。指示の本文に
# --model などが書かれていても拾わないため。
# ponytail: 位置引数や、値を取るほかの flag (--agent <名前> など) より後ろの許可 flag は取りこぼす
# (取りこぼしても再開時の設定が既定に戻るだけ)。正確にするなら sysctl KERN_PROCARGS2 で argv の境界を取る。
resume_args() {
    local w out="" i=1 n f k acc best bestk
    # 本文の * や ? をカレントのファイル名に展開しないよう、割る間だけ glob を止める。
    set -f
    read -ra w <<<"$1"
    set +f
    n=${#w[@]}
    while [ "$i" -lt "$n" ]; do # w[0] はプログラム名
        f=${w[$i]}
        case $f in
            --plugin-dir | --plugin-dir=*)
                best="" bestk=$i acc=""
                [ "$f" = --plugin-dir ] || { acc=${f#--plugin-dir=}; [ -d "$acc" ] && best=$acc; }
                k=$((i + 1))
                while [ "$k" -lt "$n" ]; do
                    case ${w[$k]} in --*) break ;; esac
                    acc=${acc:+$acc }${w[$k]}
                    if [ -d "$acc" ]; then best=$acc bestk=$k; fi
                    k=$((k + 1))
                done
                [ -z "$best" ] || out="$out --plugin-dir $(printf %q "$best")"
                i=$((bestk + 1))
                ;;
            --model | --effort)
                i=$((i + 1))
                if [ "$i" -lt "$n" ]; then
                    case ${w[$i]} in
                        -*) ;;
                        *) out="$out $f $(printf %q "${w[$i]}")"; i=$((i + 1)) ;;
                    esac
                fi
                ;;
            --model=* | --effort=*)
                case ${f#*=} in
                    '' | -*) ;;
                    *) out="$out ${f%%=*} $(printf %q "${f#*=}")" ;;
                esac
                i=$((i + 1))
                ;;
            --resume | -r)
                i=$((i + 1))
                if [ "$i" -lt "$n" ]; then case ${w[$i]} in -*) ;; *) i=$((i + 1)) ;; esac; fi
                ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    printf '%s' "$out"
}

stop() {
    local targets rows row pid want reason term agent terms path sid restore lost key rule warned msg
    if [ "${1:-}" = --listed ]; then
        targets=$(cat "$STATE_DIR/listed.tsv" 2>/dev/null)
        [ -n "$targets" ] || { echo "listed.tsv が空です。先に agent-gc list を打ってください" >&2; return 1; }
    else
        [ $# -gt 0 ] || { echo "usage: agent-gc stop <pid>... | --listed" >&2; return 1; }
        targets=$(printf '%s\t\n' "$@")
    fi
    # 共有ファイルが無ければ、何を守るかも、止めたものをどこに残すかも分からないので 1 本も止めない。
    if [ "$ledger_ok" != 1 ]; then
        log "WARN: $(dirname "$self")/cleanup-ledger.sh を読めない。1 本も止めない"
        return 1
    fi
    # 「触らない」リストは 1 回だけ読む (途中でファイルが変わっても、この回の判定は変えない)。無い・読めない回は、
    # 何を守るべきか分からないので 1 本も /exit を送らない (worktree-gc と同じ。守るものが無いことは空のファイルで表す)。
    # 通知はその日 1 回だけ。印は worktree-gc のものと分ける (片方の通知で、もう片方の知らせを消さないため)。
    # 手で流す DRY_RUN では通知も印も出さない (worktree-gc と同じ。その日の本番の通知を消さないため)。
    # 「無い」と「読めない行が在る」は印を分ける (同じ日に、無い → 作った → 書き間違い、でも 2 本目が出るように)。
    if ! keep_load; then
        if [ "$keep_error" = bad ]; then
            log "WARN: 「触らない」リスト $CLEANUP_KEEP に読めない行がある。1 本も止めない"
            warned="$STATE_DIR/keep-unreadable-warned"
            msg="「触らない」リスト $CLEANUP_KEEP に読めない行があるので stop を止めています (行番号はログに)"
        else
            log "WARN: 「触らない」リスト $CLEANUP_KEEP が無いか読めない。1 本も止めない (守るものが無ければ空のファイルを置く)"
            warned="$STATE_DIR/keep-missing-warned"
            msg="「触らない」リスト $CLEANUP_KEEP が無いので stop を止めています。守るものが無ければ空のファイルを置く"
        fi
        if [ "${DRY_RUN:-0}" != 1 ] && [ "$(cat "$warned" 2>/dev/null)" != "$(date +%F)" ]; then
            notify "$msg"
            { mkdir -p "$STATE_DIR" && date +%F >"$warned"; } 2>/dev/null || log "WARN: 通知済みの印を書けない $warned"
        fi
        return 1
    fi
    while IFS=$'\t' read -r pid want; do
        [ -n "$pid" ] || continue
        # 前の 1 本の終了待ちの間に再開されることがあるので、送る直前に 1 本ずつ取り直す
        [[ "$pid" =~ ^[0-9]+$ ]] || { log "skip pid=$pid: not a pid"; continue; }
        row=$(collect "$pid" | judge | sched)
        terms=$(orca terminal list --json 2>/dev/null)
        agent=$(jq -r '.agent // "?"' <<<"$row" 2>/dev/null)
        if [ -z "$row" ]; then log "skip pid=$pid: not running"; continue; fi
        reason=$(jq -r '.reason // empty' <<<"$row")
        if [ -n "$reason" ]; then log "skip $agent pid=$pid: $reason"; continue; fi
        if [ -n "$want" ] && [ "$want" != "$(jq -r .key <<<"$row")" ]; then log "skip $agent pid=$pid: changed since list"; continue; fi
        path=$(jq -r .path <<<"$row")
        # cwd が取れない (記録に cwd が無い、Codex の lsof が失敗した) と、リストに当たるか判定できない。
        # 材料が欠けたら止めない側に倒す (空の cwd は keep_match のどの行にも当たらず、そのまま止まってしまう)。
        case $path in /*) ;; *) log "skip $agent pid=$pid: cwd が分からない"; continue ;; esac
        if keep_match "$path"; then log "skip $agent pid=$pid: 「触らない」リストに当たる $path"; continue; fi
        term=$(jq -r .term <<<"$row")
        # agentIdentity は時々 null で返る (実測)。別のエージェントと出たときだけ止めない。入力欄は画面で確かめる。
        if [ -z "$term" ] || ! jq -e --arg h "$term" --arg a "$agent" \
            'any(.result.terminals[]?; .handle == $h and (.agentIdentity == null or .agentIdentity == $a))' <<<"$terms" >/dev/null 2>&1; then
            log "skip $agent pid=$pid: Orca の端末が見つからない"; continue
        fi
        # 台帳に残す戻し方。起動時の引数はプロセスと一緒に消えるので、/exit を送る前に組む。
        # 送る直前の確認 (下の a・b) の後に外部コマンドを挟まないよう、確認より先に組む。
        # 許可した引数は --resume の前に置く (再開したセッションを次に止めたとき、resume_args が --resume の値を
        # 位置引数と取り違えずに済む。Orca 自身の再開も --resume を最後に置く)。
        # Codex の ID は rollout の 1 行目から引けそうだが、codex resume <ID> で再開まで通るかを確かめていないので
        # 残さず、一覧から選ばせる。
        sid=$(jq -r '.sid // ""' <<<"$row")
        if [ "$agent" = claude ]; then
            restore="cd $(printf %q "$path") && claude$(resume_args "$(ps -ww -o args= -p "$pid" 2>/dev/null)") --resume${sid:+ $(printf %q "$sid")}"
            # resume で戻らないもの (https://code.claude.com/docs/en/scheduled-tasks.md の Limitations)。在ったかは見ていない。
            lost="裏のコマンド・モニター・自分で間隔を決める /loop（在ったかは分からない）"
        else
            restore="cd $(printf %q "$path") && codex resume" sid="" lost=""
        fi
        # 注記は # のコメントにしない。対話の zsh は既定で interactive_comments が無効なので、貼ると # 以降が
        # 引数として渡り、再開のときに次のターンとして実行される。: は引数を読み捨てるだけなので bash でも zsh でも無害。
        [ -n "$sid" ] || restore=": 一覧から選ぶ; $restore"
        rule="idle $(jq -r '.idle_sec / 3600 | floor' <<<"$row")h >= $(jq -r '.threshold_h' <<<"$row")h"
        [ "$(jq -r '.pressure // 0' <<<"$row")" -ge 2 ] && rule="$rule (memory pressure WARN)"
        # 判定の後に始まったターンを拾うため、送る直前に (a) 記録の読み直し、(b) 入力欄の順に続けて確かめる。
        # (a) 判定のときと同じく idle で、状態の時刻も判定のときのまま (鍵の最後の欄。lstart にも : が入るので最後を取る)。
        key=$(jq -r .key <<<"$row")
        if [ "$agent" = claude ]; then
            jq -e --arg ts "${key##*:}" '.status == "idle" and ((.statusUpdatedAt // .updatedAt) / 1000 | floor | tostring) == $ts' \
                "$CLAUDE_SESSIONS/$pid.json" >/dev/null 2>&1
        else
            [ "$(codex_state "$pid")" = "idle ${key##*:}" ]
        fi || { log "skip $agent pid=$pid: changed before send"; continue; }
        # (b) 既定の read は出力の履歴なので、差分で描いた書きかけを見落とす。今の描画 (--screen) で見る。
        # draft は Orca の入力欄に書きかけの文字。あれば使うつもりなので止めない。
        if ! orca terminal read --terminal "$term" --screen --json 2>/dev/null |
            jq -r '.result.terminal | if .source == "screen" and ((.draft // "") == "") then .tail[] else empty end' |
            prompt_empty "$agent"; then
            log "skip $agent pid=$pid: input not empty"; continue
        fi
        # (b) の後は外部コマンドを挟まずに送る。
        if [ "${DRY_RUN:-0}" = 1 ]; then echo "would stop $agent pid=$pid $path"; continue; fi
        orca terminal send --terminal "$term" --text /exit --enter --json >/dev/null 2>&1 || { log "failed $agent pid=$pid: send"; continue; }
        local lstart i
        lstart=$(jq -r .lstart <<<"$row")
        for i in $(seq 20); do
            [ "$(lstart_of "$pid")" = "$lstart" ] || break
            sleep 1
        done
        if [ "$(lstart_of "$pid")" = "$lstart" ]; then
            log "failed $agent pid=$pid: still running after /exit"
            # /exit は届いていて、待ち時間の後で終わることがある。そのとき台帳に無いと戻し方が残らないので、印を付けて書く。
            rule="$rule (/exit 送信済み・終了は未確認)"
        else
            log "stopped $agent pid=$pid idle=$(jq -r '.idle_sec / 3600 | floor' <<<"$row")h path=$path"
        fi
        # 書けなくても次の 1 本は続ける。
        ledger_add session "$agent $path" "$rule" "$restore" "$lost" || log "WARN: 台帳に書けない $CLEANUP_LEDGER"
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
