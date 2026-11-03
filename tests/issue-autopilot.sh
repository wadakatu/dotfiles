#!/usr/bin/env bash
# home/scripts/issue-autopilot.sh の候補抽出・起動・復旧・sweep を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/issue-autopilot.sh
# orca と gh は偽物。勝手に起動しないこと (無効・上限・PR あり) と、起動途中からの復旧を主に見る。
set -u
# shellcheck disable=SC2016  # '...' の中の $x は偽コマンドの変数

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/issue-autopilot.sh"
base=$(mktemp -d)
trap '[ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}
has() { grep -qF -- "$2" "$T/$1"; }
lacks() { ! grep -qF -- "$2" "$T/$1" 2>/dev/null; }
job() { awk -F'\t' -v k="o/r#$1" '$1 == k { print $2 }' "$T/state/jobs.tsv"; }
is() { [ "$1" = "$2" ]; }

mkdir -p "$base/bin"
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "api user") echo me ;;
    "issue list") cat "$FAKE/issues.json" ;;
    "issue view") cat "$FAKE/upd" ;;
    "api graphql") cat "$FAKE/graphql.json" ;;
    *) exit 1 ;;
esac
EOF
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "status --json") echo '{"result": {"runtime": {"reachable": true}}}' ;;
    "worktree list") cat "$FAKE/list.json" ;;
    "worktree ps") cat "$FAKE/ps.json" ;;
    "worktree create") echo "$*" >>"$FAKE/calls"; cat "$FAKE/create.json" ;;
    "agent launch") echo "$*" >>"$FAKE/calls"; cat "$FAKE/launch.json"; exit "$(cat "$FAKE/launch.rc" 2>/dev/null || echo 0)" ;;
    "worktree set") echo "$*" >>"$FAKE/calls"; [ -f "$FAKE/set.fail" ] && exit 1; echo '{"ok": true}' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$base/bin/"*

MAIN='{"id": "R::/co", "repoId": "R", "path": "/co", "isMainWorktree": true, "branch": "refs/heads/main"}'
setup() {
    CASE=$1
    T="$base/$CASE"
    mkdir -p "$T/state"
    : >"$T/calls"
    cat >"$T/state/config" <<EOF
repo=o/r
checkout=/co
base=main
dispatcher_worktree=/disp
card_prefix=app
ask_labels=area: auth,security
dispatch_enabled=true
max_per_run=2
max_active=3
max_per_day=4
EOF
    list "$MAIN"
    echo '{"ok": true, "result": {"worktrees": []}}' >"$T/ps.json"
    echo '[]' >"$T/issues.json"
    echo '{"ok": true, "result": {"worktree": {"id": "R::/wt/issue-1", "branch": "refs/heads/issue-1-fix-login"}}}' >"$T/create.json"
    echo '{"ok": true, "result": {"launch": {"outcome": {"kind": "chat"}}}}' >"$T/launch.json"
    graphql OPEN '"2026-01-01T00:00:00Z"' '[]'
}
list() { printf '{"ok": true, "result": {"truncated": false, "worktrees": [%s]}}\n' "$(IFS=,; echo "$*")" >"$T/list.json"; }
ps_agent() { # ps_agent <worktreeId> <paneKey> <state> <prompt> <updatedAt(ms)>
    printf '{"ok": true, "result": {"worktrees": [{"worktreeId": "%s", "agents": [{"paneKey": "%s", "state": "%s", "prompt": "%s", "updatedAt": %s}]}]}}\n' \
        "$1" "$2" "$3" "$4" "$5" >"$T/ps.json"
}
graphql() { # graphql <state> <updatedAt json> <closedBy nodes json>
    printf '{"data": {"viewer": {"login": "me"}, "repository": {"issue": {"state": "%s", "title": "Fix login", "updatedAt": %s, "author": {"login": "me"},
      "labels": {"pageInfo": {"hasNextPage": false}, "nodes": []}, "assignees": {"pageInfo": {"hasNextPage": false}, "nodes": []},
      "closedByPullRequestsReferences": {"pageInfo": {"hasNextPage": false}, "nodes": %s},
      "timelineItems": {"pageInfo": {"hasNextPage": false}, "nodes": []}}}}}\n' "$1" "$2" "$3" >"$T/graphql.json"
}
pending() { # pending <N>...: go の判定と pending の job を置く
    local n
    for n in "$@"; do
        printf 'o/r#%s\t2026-01-01T00:00:00Z\tgo\tok\t1\n' "$n" >>"$T/state/verdicts.tsv"
        printf 'o/r#%s\tpending\t-\t-\t-\t-\t-\t-\t1\t-\n' "$n" >>"$T/state/jobs.tsv"
    done
}
run() { # run <サブコマンド...>
    env PATH="$base/bin:$PATH" FAKE="$T" ISSUE_AUTOPILOT_DIR="$T/state" ISSUE_AUTOPILOT_LOG="$T/applog" \
        ISSUE_AUTOPILOT_NOW="${NOW:-100000}" bash "$script" "$@" >"$T/out" 2>"$T/log"
    echo $? >"$T/rc"
}
rc() { [ "$(cat "$T/rc")" = "$1" ]; }

# ---- candidates: 除外とルール判定 ----
setup candidates
cat >"$T/issues.json" <<'EOF'
[
 {"number": 1, "title": "Fix login", "updatedAt": "u1", "labels": [], "assignees": []},
 {"number": 2, "title": "opt out", "updatedAt": "u2", "labels": [{"name": "no-agent"}], "assignees": []},
 {"number": 3, "title": "taken", "updatedAt": "u3", "labels": [], "assignees": [{"login": "someone"}]},
 {"number": 4, "title": "has wt", "updatedAt": "u4", "labels": [], "assignees": [{"login": "me"}]},
 {"number": 5, "title": "auth", "updatedAt": "u5", "labels": [{"name": "area: auth"}], "assignees": []},
 {"number": 6, "title": "judged", "updatedAt": "u6", "labels": [], "assignees": []},
 {"number": 7, "title": "本番の設定を直す", "updatedAt": "u7", "labels": [], "assignees": []},
 {"number": 8, "title": "edited", "updatedAt": "u8-new", "labels": [], "assignees": []}
]
EOF
list "$MAIN" '{"id": "R::/wt/4", "repoId": "R", "path": "/wt/4", "isMainWorktree": false, "branch": "refs/heads/issue-4-has-wt"}'
printf 'o/r#6\tu6\tskip\tdup\t1\no/r#8\tu8-old\tgo\tok\t1\n' >"$T/state/verdicts.tsv"
run candidates
check "候補があれば exit 0" rc 0
check "素の issue は未判定" has out $'untriaged\t1\t'
check "編集された issue は再判定" has out $'untriaged\t8\t'
for n in 2 3 4 5 6 7; do check "#$n は未判定に出ない" lacks out $'untriaged\t'"$n"$'\t'; done
check "ラベルで ask" has state/verdicts.tsv $'o/r#5\tu5\task\tlabel area: auth'
check "タイトルで ask" has state/verdicts.tsv $'o/r#7\tu7\task\ttitle 本番'
check "ask を dispatcher のカードに集める" has calls "--worktree path:/disp --comment 判断待ち 2: #7 title 本番 / #5 label area: auth"
check "未判定は updatedAt の新しい順" is "$(grep ^untriaged "$T/out" | cut -f2 | tr '\n' ' ')" "8 1 "
cp "$T/calls" "$T/calls.1"
run candidates
check "同じ判断待ちはカードに打ち直さない" is "$(wc -l <"$T/calls")" "$(wc -l <"$T/calls.1")"

setup candidates-none
run candidates
check "候補が無ければ exit 1 (run を飛ばす)" rc 1

setup stale-lock
mkdir -p "$T/state/lock.d" && echo 999999 >"$T/state/lock.d/pid"
run candidates
check "死んだ pid のロックを回収する" has applog "死んだロックを回収"
check "回収後に終わってロックを消す" test ! -d "$T/state/lock.d"

# ---- dispatch ----
setup disabled
pending 1
sed -i.bak 's/^dispatch_enabled=true/dispatch_enabled=false/' "$T/state/config"
run dispatch
check "無効なら worktree を作らない" lacks calls "worktree create"
check "pending は残る" is "$(job 1)" pending

setup cooldown
pending 1
echo "cooldown_until=200000" >>"$T/state/config"
run dispatch
check "cooldown 中は作らない" lacks calls "worktree create"

setup launch
pending 1
ps_agent "R::/wt/issue-1" P1 working "/issue-worker 1" 100000000
run dispatch
check "worktree を作る" has calls "worktree create --repo path:/co --name issue-1-fix-login --branch issue-1-fix-login --issue 1 --base-branch origin/main"
check "dispatcher の子にする" has calls "--parent-worktree path:/disp"
check "worker を起動する" has calls "agent launch --agent claude --worktree id:R::/wt/issue-1 --model opus --effort high --surface chat --prompt /issue-worker 1 --json"
check "カード名に接頭辞" has calls "--display-name app: #1 Fix login"
check "paneKey を取れたら running" is "$(job 1)" running
check "jobs に paneKey" has state/jobs.tsv $'\tP1\t'
check "日次枠を予約" has state/launches.log $'\treserved'
check "起動を記録" has state/launches.log $'\tlaunched'

setup per-run-limit
pending 1 2
sed -i.bak 's/^max_per_run=2/max_per_run=1/' "$T/state/config"
run dispatch
check "1 run の上限で 1 件だけ作る" is "$(grep -c 'worktree create' "$T/calls")" 1
check "残りは pending" is "$(job 2)" pending

setup daily-limit
pending 1
for i in 1 2 3 4; do printf 'x\t1\t%s\to/r#9%s\treserved\n' "$(TZ=Asia/Tokyo date +%F)" "$i" >>"$T/state/launches.log"; done
run dispatch
check "1 日の上限で作らない" lacks calls "worktree create"

setup pr-exists
pending 1
graphql OPEN '"2026-01-01T00:00:00Z"' '[{"state": "MERGED"}]'
run dispatch
check "PR があれば作らない" lacks calls "worktree create"
check "job を消す" is "$(job 1)" ""
check "ask pr-exists にする" has state/verdicts.tsv $'\task\tpr-exists'

setup owner
pending 1
list "$MAIN" '{"id": "R::/other", "repoId": "R", "path": "/other", "isMainWorktree": false, "branch": "refs/heads/x", "linkedIssue": 1}'
run dispatch
check "他の worktree があれば作らない" lacks calls "worktree create"
check "ask owner にする" has state/verdicts.tsv $'\task\towner'

setup changed
pending 1
graphql OPEN '"2026-02-02T00:00:00Z"' '[]'
run dispatch
check "編集された issue は作らない" lacks calls "worktree create"
check "verdict を消して再判定へ" lacks state/verdicts.tsv "o/r#1"

setup lost-reply
pending 1
echo '{"ok": false, "error": {"code": "launch_reply_lost", "operationId": "OP123"}}' >"$T/launch.json"
echo 1 >"$T/launch.rc"
run dispatch
check "返事を失ったら launching のまま" is "$(job 1)" launching
check "operationId を残す" has state/jobs.tsv $'\tOP123\t'
: >"$T/calls"; rm "$T/launch.rc"
echo '{"ok": true, "result": {}}' >"$T/launch.json"
list "$MAIN" '{"id": "R::/wt/issue-1", "repoId": "R", "path": "/wt/issue-1", "isMainWorktree": false, "branch": "refs/heads/issue-1-fix-login"}'
run dispatch
check "agent が見えなければ --retry-launch" has calls "--retry-launch OP123"
check "新しい worktree は作らない" lacks calls "worktree create"
: >"$T/calls"
ps_agent "R::/wt/issue-1" P1 working "/issue-worker 1" 100000000
run dispatch
check "agent が見えたら起動し直さない" lacks calls "agent launch"
check "復旧して running" is "$(job 1)" running

# ---- sweep (candidates の中) ----
setup sweep
W='{"id": "R::/wt/a", "repoId": "R", "path": "/wt/a", "isMainWorktree": false, "branch": "refs/heads/issue-1-a"}'
list "$MAIN" "$W"
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
printf 'o/r#2\trunning\tissue-2-b\tR::/wt/b\tok:1\tPB\t-\t99000\t1\t-\n' >>"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA done "/issue-worker 1" 100000000
run candidates
check "PR 無しで終わった agent は failed" is "$(job 1)" failed
check "worker のカードを Needs decision に" has calls "--worktree id:R::/wt/a --comment #1 no-pr 終了したが PR なし --json --workspace-status needs-decision"
check "worktree が消えたら failed" is "$(job 2)" failed
check "1 時間に 2 件の失敗で cooldown" has state/config "cooldown_until=107200"

setup stalled
list "$MAIN" '{"id": "R::/wt/a", "repoId": "R", "path": "/wt/a", "isMainWorktree": false, "branch": "refs/heads/issue-1-a"}'
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA working "/issue-worker 1" 90000000
run candidates
check "2 時間動かなければ stalled" is "$(job 1)" stalled
check "stalled はカードに出す" has calls "停止: #1"

# ---- worker からの記録 ----
setup done
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
run done 1 https://github.com/o/r/pull/9
check "done で pr_opened" is "$(job 1)" pr_opened
check "PR の URL を残す" has state/jobs.tsv "https://github.com/o/r/pull/9"

setup resume-refused
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
run resume 1 "続けて"
check "running の job は resume しない" lacks calls "agent launch"

# ---- レビュー指摘の回帰 ----
setup last-label
echo '[{"number": 1, "title": "x", "updatedAt": "u1", "labels": [{"name": "security"}], "assignees": []}]' >"$T/issues.json"
run candidates
check "カンマ区切りの最後のラベルも見る" has state/verdicts.tsv $'\task\tlabel security'

setup launching-only
printf 'o/r#1\tlaunching\tissue-1-a\tR::/wt/a\tOP1\t-\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
list "$MAIN" '{"id": "R::/wt/a", "repoId": "R", "path": "/wt/a", "isMainWorktree": false, "branch": "refs/heads/issue-1-a"}'
run candidates
check "launching だけでも precheck を通す" rc 0
check "launching を出す" has out $'launching\t1'

setup dry-run-recover
printf 'o/r#1\tlaunching\tissue-1-a\tR::/wt/a\tOP1\t-\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
list "$MAIN" '{"id": "R::/wt/a", "repoId": "R", "path": "/wt/a", "isMainWorktree": false, "branch": "refs/heads/issue-1-a"}'
DRY_RUN=1 run dispatch
check "DRY_RUN の復旧は起動しない" lacks calls "agent launch"

setup verdict-revoke
pending 1
echo "2026-01-01T00:00:00Z" >"$T/upd"
run verdict 1 ask "spec"
check "ask にしたら pending を消す" is "$(job 1)" ""

setup not-go
printf 'o/r#1\t2026-01-01T00:00:00Z\task\tspec\t1\n' >"$T/state/verdicts.tsv"
printf 'o/r#1\tpending\t-\t-\t-\t-\t-\t-\t1\t-\n' >"$T/state/jobs.tsv"
run dispatch
check "判定が go でない pending は起動しない" lacks calls "worktree create"

setup pr-exists-upd
pending 1
graphql OPEN '"2026-01-01T00:00:00Z"' '[{"state": "OPEN"}]'
run dispatch
check "pr-exists の判定に issue の updatedAt" has state/verdicts.tsv $'o/r#1\t2026-01-01T00:00:00Z\task\tpr-exists'

setup resume-working
W='{"id": "R::/wt/a", "repoId": "R", "path": "/wt/a", "isMainWorktree": false, "branch": "refs/heads/issue-1-a"}'
list "$MAIN" "$W"
printf 'o/r#1\tstalled\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t90000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA working "/issue-worker 1" 100000000
run resume 1 "続けて"
check "動いている agent がいれば resume しない" lacks calls "agent launch"

setup resume-exclude
list "$MAIN" "$W"
printf 'o/r#1\tfailed\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t90000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA done "/issue-worker 1" 100000000
echo '{"ok": false, "error": {"operationId": "OP9"}}' >"$T/launch.json"; echo 1 >"$T/launch.rc"
run resume 1 "続けて"
rm "$T/launch.rc"; : >"$T/calls"
run dispatch
check "resume 前の pane を拾わず --retry-launch" has calls "--retry-launch OP9"

setup skip-working
list "$MAIN" "$W"
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA working "/issue-worker 1" 100000000
echo "2026-01-01T00:00:00Z" >"$T/upd"
run skip 1
check "動いている job は skip で枠を離さない" is "$(job 1)" running

setup resume-limit
list "$MAIN" "$W"
for i in 2 3 4; do printf 'o/r#%s\trunning\tb\tR::/wt/%s\tok:1\tP%s\t-\t99000\t1\t-\n' "$i" "$i" "$i" >>"$T/state/jobs.tsv"; done
printf 'o/r#1\tfailed\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t90000\t1\t-\n' >>"$T/state/jobs.tsv"
run resume 1 "続けて"
check "稼働が上限なら failed から resume しない" lacks calls "agent launch"

setup resume-twice
list "$MAIN" "$W"
printf 'o/r#1\tfailed\tissue-1-a\tR::/wt/a\tok:1\tP1\t-\t90000\t1\t-\n' >"$T/state/jobs.tsv"
mkdir -p "$T/state/prompts"; echo P0 >"$T/state/prompts/1.exclude"
ps_agent "R::/wt/a" P0 done "/issue-worker 1 --resume 'x'" 100000000
echo '{"ok": false, "error": {"operationId": "OP9"}}' >"$T/launch.json"; echo 1 >"$T/launch.rc"
run resume 1 "続けて"
rm "$T/launch.rc"; : >"$T/calls"
run dispatch
check "2 回前の pane も拾わない" has calls "--retry-launch OP9"

setup asks-zero
run candidates
check "判断待ち 0 でカードを作業中・既読に戻す" has calls "--comment 判断待ち 0 --json --workspace-status in-progress --read"

setup verdict-stale
echo "2026-02-02T00:00:00Z" >"$T/upd"
run verdict 1 go "ok" "2026-01-01T00:00:00Z"
check "読んだ版と違えば判定を書かない" lacks state/verdicts.tsv "o/r#1"
check "版違いは exit 3" rc 3
check "job も作らない" is "$(job 1)" ""

setup launching-wt-gone
printf 'o/r#1\tlaunching\tissue-1-a\tR::/wt/gone\tOP1\t-\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
run dispatch
check "起動途中に worktree が消えたら failed で枠を離す" is "$(job 1)" failed
check "消えた worktree へ起動しない" lacks calls "agent launch"

setup board-retry
list "$MAIN" "$W"
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA working "/issue-worker 1" 90000000
touch "$T/set.fail"
run candidates
check "通知に失敗しても stalled にはする" is "$(job 1)" stalled
rm "$T/set.fail"; : >"$T/calls"
run candidates
check "送れなかったカードを次の sweep で送り直す" has calls "--worktree id:R::/wt/a --comment 停止: #1"
check "送れたら再送の対象から消す" lacks state/board-retry.tsv "id:R::/wt/a"

setup recover-cooldown
printf 'o/r#2\tlaunching\tb\tR::/wt/gone2\tOP1\t-\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
printf 'o/r#3\tlaunching\tc\tR::/wt/gone3\tOP1\t-\t-\t99000\t1\t-\n' >>"$T/state/jobs.tsv"
pending 1
run dispatch
check "復旧中に cooldown に入ったら pending を起動しない" lacks calls "worktree create"

setup waiting
list "$MAIN" "$W"
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA waiting "/issue-worker 1" 99990000
run candidates
check "入力待ちの worker は stalled にして人に回す" is "$(job 1)" stalled
check "入力待ちをボードに出す" has calls "入力待ち: #1"
run resume 1 "続けて"
check "入力待ちの agent が残っていれば resume しない" lacks calls "agent launch"

setup tsv-escape
printf 'o/r#1\trunning\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
run fail 1 red 'fix \n and \t handling'
check "補足の \\n で行が割れない" is "$(wc -l <"$T/state/jobs.tsv" | tr -d ' ')" 1

setup prompt-reset
pending 1
mkdir -p "$T/state/prompts"; printf "/issue-worker 1 --resume 'old'" >"$T/state/prompts/1"
echo '{"ok": false}' >"$T/create.json"
run dispatch
check "新規起動の前に前回の resume 指示を消す" is "$(cat "$T/state/prompts/1")" "/issue-worker 1"

setup create-fail-cooldown
printf 'o/r#2\tlaunching\tissue-2-b\t-\t-\t-\t-\t99000\t1\t-\n' >"$T/state/jobs.tsv"
printf 'o/r#3\tlaunching\tissue-3-c\t-\t-\t-\t-\t99000\t1\t-\n' >>"$T/state/jobs.tsv"
pending 1
run dispatch
check "作成失敗が 2 件続いたら同じ dispatch で作らない" lacks calls "worktree create"

setup launch-timeout
list "$MAIN" "$W"
printf 'o/r#1\tlaunching\tissue-1-a\tR::/wt/a\t-\t-\t-\t90000\t1\t-\n' >"$T/state/jobs.tsv"
run dispatch
check "1 時間起動できない job は failed にして枠を空ける" is "$(job 1)" failed
check "起動できない job は再起動しない" lacks calls "agent launch"

setup board-back
list "$MAIN" "$W"
printf 'o/r#1\tfailed\tissue-1-a\tR::/wt/a\tok:1\tPA\t-\t90000\t1\t-\n' >"$T/state/jobs.tsv"
ps_agent "R::/wt/a" PA done "/issue-worker 1" 100000000
run resume 1 "続けて"
check "resume でカードを作業中に戻す" has calls "--comment 再開: #1 --json --workspace-status in-progress"
run done 1 https://github.com/o/r/pull/9
check "done は exit 0" rc 0
check "PR を出したらカードをレビュー待ちに" has calls "--comment PR #9 --json --workspace-status in-review"

[ "$fail" = 0 ] && echo "ok: issue-autopilot"
exit "$fail"
