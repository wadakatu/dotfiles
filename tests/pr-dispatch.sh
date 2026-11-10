#!/usr/bin/env bash
# home/scripts/pr-dispatch.sh の「起動してよいか」の判定を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/pr-dispatch.sh
# git と jq は本物、orca / gh / sysctl は偽物。無人でエージェントを起動するスクリプトなので、
# 起動してはいけないとき (観測が欠けた、人が作業中、再開したセッションが始まる前、結果の分からない起動の後) に
# 起動しないことを主に見る。
set -u
# shellcheck disable=SC2016  # '...' の中の $x は偽コマンドの変数

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/pr-dispatch.sh"
base=$(mktemp -d)
base=$(cd "$base" && pwd -P)
export GIT_CONFIG_GLOBAL="$base/gitconfig" GIT_CONFIG_NOSYSTEM=1 # 手元の hook や署名の設定を巻き込まない
git config -f "$GIT_CONFIG_GLOBAL" user.name t
git config -f "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
trap '[ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
CASE=""
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}

# 状態の置き場所は STATE_ROOT の 1 つから決まること。スクリプトが実際のディレクトリを直接指していると、
# このテストが本物の状態 (セッションの印、起動の記録) を書き換える。そのときは何も走らせない。
for f in pr-dispatch agent-resume dispatch-lock; do
    direct=$(grep -v '^[[:space:]]*#' "$root/home/scripts/$f.sh" | grep 'HOME/Library' | grep -vc '^STATE_ROOT="\${STATE_ROOT:-')
    [ "$direct" = 0 ] || { echo "$f.sh が STATE_ROOT を通さずに状態の場所を決めている。中止"; exit 1; }
done

# ---- 偽のコマンド ----
mkdir -p "$base/bin"
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
echo "orca $*" >>"$FAKE/calls"
reply() { cat "$FAKE/$1" 2>/dev/null; exit "$(cat "$FAKE/$1.rc" 2>/dev/null || echo 0)"; }
case "$1 $2" in
    "status --json") [ -e "$FAKE/orca-down" ] && exit 1; echo '{"result":{"runtime":{"reachable":true}}}' ;;
    "worktree list") reply list.json ;;
    "worktree ps") reply ps.json ;;
    "worktree set") reply set.json ;;
    "terminal list") reply terms.json ;;
    "terminal read") cat "$FAKE/read.json" 2>/dev/null || echo '{"result":{"terminal":{"tail":[]}}}' ;;
    "repo show") cat "$FAKE/repo.json" 2>/dev/null || echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":""}}}}}' ;;
    "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_new","paneKey":"tabn:leafn"}}}' ;;
    "worktree create")
        # create.json があればそれを返す (失敗や、読めない返事)。無ければ本物の git worktree を作る。
        [ -e "$FAKE/create.json" ] && reply create.json
        while [ $# -gt 0 ]; do
            case "$1" in
                --repo) main=${2#path:} ;;
                --name) name=$2 ;;
                --branch) br=$2 ;;
                --base-branch) from=$2 ;;
            esac
            shift
        done
        # 使用済みの名前には数字を足す (本物の Orca と同じ)。
        git -C "$main" show-ref --verify --quiet "refs/heads/$br" && br="$br-2"
        d="$ORCA_ROOT/r/$name"
        git -C "$main" worktree add -q -b "$br" "$d" "$from" 2>/dev/null || exit 1
        # create-then-block: 作った直後に、PR の branch を別の checkout で使用中にする (切り替えを git が拒否する)。
        [ -e "$FAKE/create-then-block" ] && git -C "$main" worktree add -q "$FAKE/../other" "${from#origin/}"
        jq -cn --arg p "$d" --arg b "refs/heads/$br" '{ok: true, result: {warnings: [], worktree: {id: ("r::" + $p), path: $p, branch: $b}}}'
        ;;
    "agent launch") reply launch.json ;;
    *) echo '{"ok":true}' ;;
esac
EOF
# graphql は、開いている PR の問い合わせには prs.json (ページごとの JSON)、クローズ済みには closed.tsv を返す。
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE/calls"
[ -e "$FAKE/gh-down" ] && exit 1
case "$1 $2" in
    "api user") echo me ;;
    "api graphql") case "$*" in *is:closed*) cat "$FAKE/closed.tsv" ;; *) cat "$FAKE/prs.json" ;; esac ;;
    "pr list") echo 0 ;;
esac
EOF
cat >"$base/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *kern.bootsessionuuid*) echo BOOT-NOW ;;
    *kern.boottime*) echo '{ sec = 1700000000, usec = 0 } Tue Nov 14 22:13:20 2023' ;;
esac
EOF
# $FAKE/tick があるときだけ、+%s を呼ぶたびに 1 秒進む時計になる。同じ 1 秒の中で終わる実行では、
# 「別々に取った 2 つの時刻」が同じ値になって、取り違えが見えないため。それ以外は本物の date。
cat >"$base/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "+%s" ] && [ -e "$FAKE/tick" ]; then
    n=$(($(cat "$FAKE/tick") + 1))
    echo "$n" >"$FAKE/tick"
    echo "$n"
else
    exec /bin/date "$@"
fi
EOF
chmod +x "$base/bin"/*
export PATH="$base/bin:$PATH"
# 本物の orca や gh に届くと、手元のエージェントを起動してしまう。偽物が先に効いていなければ止める。
for c in orca gh sysctl date; do
    [ "$(command -v "$c")" = "$base/bin/$c" ] || { echo "偽の $c が効いていない。中止"; exit 1; }
done

export FAKE="$base/fake" STATE_ROOT="$base/state" ORCA_ROOT="$base/workspaces" CLAUDE_HOME="$base/claude"
export DISPATCH_LOCK_WAIT=0 LAUNCH_INTERVAL=0 VERBOSE=1
S="$STATE_ROOT/pr-dispatch"
R="$STATE_ROOT/agent-resume"

setup() { # setup <ケース名>: 状態と偽の入力を作り直す
    CASE=$1
    rm -rf "$STATE_ROOT" "$FAKE" "$ORCA_ROOT" "$base/main" "$base/origin" "$base/other"
    mkdir -p "$S" "$R/sessions" "$FAKE" "$ORCA_ROOT"
    : >"$FAKE/calls"
    : >"$FAKE/wts"
    : >"$FAKE/nodes"
    : >"$FAKE/closed.tsv"
    echo '{"ok":true}' >"$FAKE/launch.json"
    echo '{"ok":true}' >"$FAKE/set.json"
    echo '{"result":{"terminals":[],"truncated":false}}' >"$FAKE/terms.json"
}
# wt <名前> <branch> <ボードの列> [エージェントの JSON 配列] [カードのコメント]: Orca の worktree を 1 つ作る (本物の git リポジトリ)。
wt() {
    local d="$ORCA_ROOT/r/$1"
    git init -q "$d"
    git -C "$d" remote add origin https://github.com/o/r.git
    git -C "$d" commit -q --allow-empty -m init
    jq -cn --arg p "$d" --arg b "refs/heads/$2" --arg s "$3" --argjson a "${4:-[]}" --arg c "${5:-}" \
        '{worktreeId: ("r::" + $p), path: $p, branch: $b, workspaceStatus: $s, isMainWorktree: false, agents: $a, comment: $c, repoId: "r"}' >>"$FAKE/wts"
}
p() { echo "$ORCA_ROOT/r/$1"; }
# agent <state> [paneKey] [prompt] [stateStartedAt (ミリ秒)]
agent() { jq -cn --arg s "$1" --arg k "${2:-t0:l0}" --arg q "${3-x}" --argjson at "${4:-1}" '[{state: $s, paneKey: $k, prompt: $q, stateStartedAt: $at, updatedAt: $at}]'; }
# pr <番号> <branch> <mergeable> <CI> <mergeStateStatus> [未対応のコメント ID] [スレッドが 100 を超えるか] [head の SHA]
# 環境変数: PR_AUTHOR (既定 me)、PR_CREATED (既定は今日)、PR_CROSS (fork からなら true)
pr() {
    jq -cn --argjson n "$1" --arg b "$2" --arg m "$3" --arg ci "$4" --arg ms "$5" --arg c "${6:-}" --argjson more "${7:-false}" --arg sha "${8:-sha$1}" \
        --arg author "${PR_AUTHOR:-me}" --arg created "${PR_CREATED:-$(/bin/date +%Y-%m-%d)}T00:00:00Z" --argjson cross "${PR_CROSS:-false}" '
        {number: $n, url: ("https://github.com/o/r/pull/" + ($n | tostring)), headRefName: $b, headRefOid: $sha,
         title: ("PR の題名 " + ($n | tostring)), createdAt: $created, isCrossRepository: $cross, author: {login: $author},
         mergeable: $m, mergeStateStatus: $ms, autoMergeRequest: null, repository: {nameWithOwner: "o/r"},
         commits: {nodes: [{commit: {statusCheckRollup: {state: $ci}}}]},
         reviewThreads: {pageInfo: {hasNextPage: $more},
           nodes: (if $c == "" then [] else [{isResolved: false, comments: {nodes: [{id: $c, author: {login: "someone"}}]}}] end)}}' >>"$FAKE/nodes"
}
page() { jq -cs '{data: {search: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}'; }
render() { # wts と nodes から、偽の orca / gh が返す JSON を作る
    jq -cs '{result: {worktrees: ., truncated: false}}' "$FAKE/wts" >"$FAKE/list.json"
    jq -c --argjson t "${PS_TRUNC:-false}" '.result.truncated = $t' "$FAKE/list.json" >"$FAKE/ps.json"
    [ -e "$FAKE/prs.fixed" ] || page <"$FAKE/nodes" >"$FAKE/prs.json"
}
run() {
    render
    bash "$script" >"$base/out" 2>&1
    rc=$?
}
called() { grep -qF -- "$1" "$FAKE/calls"; }
not_called() { ! grep -qF -- "$1" "$FAKE/calls"; }
count() { grep -cF -- "$1" "$FAKE/calls" || true; }
launched() { called "agent launch --agent claude --worktree path:$(p "$1") "; }
not_launched() { not_called "agent launch --agent claude --worktree path:$(p "$1") "; }
no_launch() { not_called "agent launch"; }
logged() { grep -qF -- "$1" "$base/out"; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null; }
# pending <handle> <paneKey> <worktree の名前> <sid> [時刻]: 再開待ちの行を 1 つ置く
pending() { printf '%s\t%s\tr::%s\t%s\t%s\n' "$1" "$2" "$(p "$3")" "$4" "${5:-$(date +%s)}" >>"$R/resume-pending.tsv"; }
term() { jq -cn --arg h "$1" --arg w "r::$(p "$2")" '{handle: $h, worktreeId: $w}'; } # term <handle> <worktree の名前>
terms() { jq -cs --argjson t "${TRUNC:-false}" '{result: {terminals: ., truncated: $t}}' >"$FAKE/terms.json"; }

# ---- 基本 ----
setup "conflict の PR"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
run
check "exit 0" [ "$rc" = 0 ]
check "/sync-pr を起動する" called "--prompt /sync-pr https://github.com/o/r/pull/1"
check "起動済みとして覚える" has "$S/dispatched.tsv" "o/r#1	sync-pr	sha1"
check "起動の前後を記録する" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching launched " ]
check "指示に、起動ごとの印を入れる" grep -Eq '\(pr-dispatch による自動起動 [0-9]+。' "$FAKE/calls"

setup "指示の印と記録の時刻は、途中で時計が進んでも同じ値"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
/bin/date +%s >"$FAKE/tick"
run
check "同じ値" called "(pr-dispatch による自動起動 $(head -1 "$S/launches.tsv" | cut -f1)。"
check "開いている PR を全ページ読む指定で問い合わせる" called "gh api graphql --paginate -f q=is:pr is:open"
check "クローズ済みの PR も全ページ読む指定で問い合わせる" called "gh api graphql --paginate -f q=is:pr is:closed"
run
check "同じ状態には起動し直さない" [ "$(count 'agent launch')" = 1 ]

setup "CI 失敗と未対応のレビュー"
wt a feat-a in-progress
wt b feat-b in-progress
pr 1 feat-a MERGEABLE FAILURE BLOCKED
pr 2 feat-b MERGEABLE SUCCESS BLOCKED c9
run
check "/fix-ci" called "--prompt /fix-ci https://github.com/o/r/pull/1"
check "/review-pr-comments" called "--prompt /review-pr-comments https://github.com/o/r/pull/2"
check "レビューの状態は head とコメント ID" has "$S/dispatched.tsv" "o/r#2	review-pr-comments	sha2:c9"

setup "1 回の起動は 3 つまで"
for n in 1 2 3 4; do wt "w$n" "feat-$n" in-progress; pr "$n" "feat-$n" CONFLICTING SUCCESS DIRTY; done
run
check "3 つ起動する" [ "$(count 'agent launch')" = 3 ]
run
check "残りは次の回" [ "$(count 'agent launch')" = 4 ]

setup "2 ページ目の PR"
wt a feat-a in-progress
wt b feat-b in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
page <"$FAKE/nodes" >"$FAKE/prs.json"
: >"$FAKE/nodes"
pr 2 feat-b CONFLICTING SUCCESS DIRTY
page <"$FAKE/nodes" >>"$FAKE/prs.json"
: >"$FAKE/prs.fixed"
run
check "1 ページ目" launched a
check "2 ページ目" launched b

setup "レビューのスレッドが 100 を超える"
wt a feat-a in-progress
pr 1 feat-a MERGEABLE SUCCESS CLEAN "" true
run
check "起動しない" no_launch
check "マージ可にもしない (未対応が無いとは言えない)" not_called "マージ可"

# ---- 観測が欠けた回は起動しない ----
for broken in orca-down gh-down list.json.rc ps.json.rc; do
    setup "観測が欠ける: $broken"
    wt a feat-a in-progress
    pr 1 feat-a CONFLICTING SUCCESS DIRTY
    echo 1 >"$FAKE/$broken"
    run
    check "exit 0" [ "$rc" = 0 ]
    check "起動しない" no_launch
done

setup "エージェントの一覧が途中で切れている"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
PS_TRUNC=true run
check "起動しない" no_launch
check "理由をログに出す" logged "途中で切れた"

# ---- 起動しない条件 ----
setup "BRAKE"
wt a feat-a in-progress
wt b feat-b in-progress
wt c feat-c in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pr 2 feat-b MERGEABLE SUCCESS CLEAN
# 前の起動の印は、PR の無い worktree に置く (a に置くと、再開待ちとして飛ばされて BRAKE を確かめられない)。
printf 'BOOT-OLD\t1\tr::%s\t%s\t%s\n' "$(p c)" "$(p c)" "$base/none.jsonl" >"$R/sessions/sid-1"
: >"$S/BRAKE"
run
check "起動しない" no_launch
check "再開もしない" not_called "terminal create"
check "ボードは更新する" called "マージ可: #2"
rm "$S/BRAKE"
run
check "外したら起動する" launched a
check "外したら再開する" called "terminal create --worktree id:r::$(p c)"

setup "Needs decision のカード"
wt a feat-a needs-decision
pr 1 feat-a CONFLICTING SUCCESS DIRTY
run
check "起動しない" no_launch

setup "エージェントが動いている"
wt a feat-a in-progress "$(agent working)"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
run
check "起動しない" no_launch

setup "エージェントは終わっている"
wt a feat-a in-progress "$(agent done)"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
run
check "起動する" launched a

setup "未コミットの変更がある"
wt a feat-a in-progress
wt b feat-b in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pr 2 feat-b CONFLICTING SUCCESS DIRTY
echo wip >"$(p a)/new-file"
run
check "変更のある worktree には起動しない" not_launched a
check "変更の無い worktree には起動する" launched b
check "カードで知らせる (列は動かさない)" called "worktree set --worktree path:$(p a) --comment 未コミットの変更があるので、自動の /sync-pr を見送り: #1 --json --unread"
run
check "同じ状態で知らせ直さない" [ "$(count '未コミットの変更')" = 1 ]
rm "$(p a)/new-file"
run
check "片付いたら起動する" launched a

# ---- 回数の上限 ----
setup "3 回起動しても直らない (最後の起動が何も push しなかった)"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
printf 'o/r#1\tsync-pr\tsha-x\no/r#1\tsync-pr\tsha-y\no/r#1\tsync-pr\tsha1\n' >"$S/dispatched.tsv"
run
check "起動しない" no_launch
check "人に上げる" called "--comment 自動の /sync-pr を 3 回起動しても直らない: #1 --json --unread --workspace-status needs-decision"

setup "2 回目までは、起動済みの状態を黙って飛ばす"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
printf 'o/r#1\tsync-pr\tsha-x\no/r#1\tsync-pr\tsha1\n' >"$S/dispatched.tsv"
run
check "起動しない" no_launch
check "人には上げない" not_called "worktree set"

setup "状態が変わっていれば 3 回目を起動する"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
printf 'o/r#1\tsync-pr\tsha-x\no/r#1\tsync-pr\tsha-y\n' >"$S/dispatched.tsv"
run
check "起動する" launched a

# ---- ボード ----
setup "ボードが warnings を返す (列の内部名が変わった)"
wt a feat-a in-progress
pr 1 feat-a MERGEABLE SUCCESS CLEAN
echo '{"ok":true,"result":{"warnings":["unknown status"]}}' >"$FAKE/set.json"
run
check "書こうとする" [ "$(count 'マージ可: #1')" = 1 ]
check "書けたことにしない" lacks "$S/board.tsv" "merge"
run
check "次の回にもう一度書く" [ "$(count 'マージ可: #1')" = 2 ]
echo '{"ok":true}' >"$FAKE/set.json"
run
run
check "書けたら、それ以上は書かない" [ "$(count 'マージ可: #1')" = 3 ]

setup "マージ待ちのカードは In review に置く"
wt a feat-a in-progress
wt b feat-b needs-decision
wt c feat-c in-progress
pr 1 feat-a MERGEABLE SUCCESS CLEAN
pr 2 feat-b MERGEABLE SUCCESS CLEAN
pr 3 feat-c MERGEABLE SUCCESS BLOCKED
run
run
check "未読と「マージ可」を付けて In review に (1 回だけ)" [ "$(count "worktree set --worktree path:$(p a) --comment マージ可: #1 --json --unread --workspace-status in-review")" = 1 ]
check "別の理由で Needs decision にあるカードは動かさない" not_called "path:$(p b) "
check "マージできない PR には付けない" not_called "マージ可: #3"
check "Needs decision には置かない" not_called "needs-decision"

setup "以前の版が Needs decision に置いた「マージ判断」のカード"
wt a feat-a needs-decision "[]" "マージ判断: #1（CLEAN・auto-merge なし）"
wt b feat-b needs-decision "[]" "どちらの案にしますか"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pr 2 feat-b CONFLICTING SUCCESS DIRTY
run
check "In review に戻す (コメントと未読は変えない)" called "worktree set --worktree path:$(p a) --workspace-status in-review --json"
check "戻した回から、conflict に対応する" launched a
check "質問のカードは動かさない" not_called "path:$(p b) --workspace-status in-review"
check "質問のカードの PR には起動しない" not_launched b

setup "「マージ判断」のカードを戻せない (列の内部名が変わった)"
wt a feat-a needs-decision "[]" "マージ判断: #1（CLEAN・auto-merge なし）"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
echo '{"ok":true,"result":{"warnings":["unknown status"]}}' >"$FAKE/set.json"
run
check "戻せていないカードの PR には起動しない" no_launch

setup "「マージ判断」のカードと DRY_RUN"
wt a feat-a needs-decision "[]" "マージ判断: #1（CLEAN・auto-merge なし）"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "カードは動かさない" not_called "worktree set"
check "動かす予定を出す" logged "DRY-RUN: board マージ判断のカードを In review に戻す"

setup "branch の無い worktree (detached HEAD)"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
jq -c '.branch = null | .workspaceStatus = "needs-decision"' "$FAKE/wts" >"$FAKE/wts.new" && mv "$FAKE/wts.new" "$FAKE/wts"
run
check "exit 0" [ "$rc" = 0 ]
check "対象にしない" no_launch

# ---- 起動の結果 ----
setup "起動が失敗を返す"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
echo '{"ok":false,"error":{"code":"x"}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
check "失敗を記録する" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching fail " ]
check "起動済みにしない" lacks "$S/dispatched.tsv" "o/r#1"
run
check "次の回に、新しい起動として試し直す" [ "$(count 'agent launch')" = 2 ]
check "出し直しの指定は付けない" not_called "--retry-launch"
run
run
check "3 回失敗したら、それ以上は試さない" [ "$(count 'agent launch')" = 3 ]
check "人に上げる" called "自動の /sync-pr の起動に 3 回失敗: #1"

setup "起動の返事を失う"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
/bin/date +%s >"$FAKE/tick"
echo '{"ok":false,"error":{"code":"reply_lost","data":{"operationId":"op_1"}}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
check "operationId を残す" has "$S/launches.tsv" "	lost	op_1	"
echo '{"ok":true}' >"$FAKE/launch.json"
echo 0 >"$FAKE/launch.json.rc"
run
check "次の回は、同じ依頼を出し直す" called "--json --retry-launch op_1"
check "出し直しの指示は、最初の依頼と同じ (印も同じ)" [ "$(grep -c "pr-dispatch による自動起動 $(head -1 "$S/launches.tsv" | cut -f1)。" "$FAKE/calls")" = 2 ]
check "通ったら起動済みにする" has "$S/dispatched.tsv" "o/r#1	sync-pr	sha1"

setup "起動の結果が分からない"
wt a feat-a in-progress "$(agent done t9:l9 old 1000)"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
: >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
check "launching のまま残る" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching " ]
run
check "起動し直さない (前から居て終わっているエージェントは、起動できた証拠にしない)" [ "$(count 'agent launch')" = 1 ]
check "まだ人には上げない" not_called "起動できたか分からない"
LAUNCH_UNKNOWN_AFTER=0 run
check "時間が経ったら人に上げる" called "自動の /sync-pr を起動できたか分からない: #1"
check "それでも起動し直さない" [ "$(count 'agent launch')" = 1 ]
check "記録を閉じる" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching unknown " ]
jq -c '.workspaceStatus = "in-progress"' "$FAKE/wts" >"$FAKE/wts.new" && mv "$FAKE/wts.new" "$FAKE/wts"
LAUNCH_UNKNOWN_AFTER=0 run
check "人がカードを戻しても、同じ状態には起動し直さない" [ "$(count 'agent launch')" = 1 ]
check "知らせるのは 1 回" [ "$(count '起動できたか分からない')" = 1 ]

setup "結果の分からない起動を閉じる前に、ボードに書けない"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
: >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
echo '{"ok":true,"result":{"warnings":["unknown status"]}}' >"$FAKE/set.json"
LAUNCH_UNKNOWN_AFTER=0 run
check "人に知らせられるまで、記録は閉じない" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching " ]
check "起動し直さない" [ "$(count 'agent launch')" = 1 ]

setup "結果の分からない起動のあとに、PR の状態が変わる"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
/bin/date +%s >"$FAKE/tick"
: >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
echo '{"ok":true}' >"$FAKE/launch.json"
echo 0 >"$FAKE/launch.json.rc"
: >"$FAKE/nodes"
pr 1 feat-a CONFLICTING SUCCESS DIRTY "" false sha-new
run
check "結果が分かるまで、新しい状態にも起動しない" [ "$(count 'agent launch')" = 1 ]
LAUNCH_UNKNOWN_AFTER=0 run
check "待っても現れなければ、新しい状態に起動する" [ "$(count 'agent launch')" = 2 ]
check "状態が変わっているので、人には上げない" not_called "起動できたか分からない"
check "前の起動は閉じる" has "$S/launches.tsv" "	unknown	-	o/r#1	sync-pr	sha1"
check "新しい起動の記録は、前の起動の時刻を引き継がない" [ "$(awk -F'\t' 'NR == 1 { t = $1 } $6 == "sha-new" && $2 == "launching" { print ($1 > t) }' "$S/launches.tsv")" = 1 ]
check "新しい状態を起動済みにする" has "$S/dispatched.tsv" "o/r#1	sync-pr	sha-new"

setup "Orca が結果不明と答える (operationId なし)"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
echo '{"ok":false,"error":{"code":"agent_session_operation_unknown","message":"x"}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
check "失敗とは記録しない" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching " ]
run
check "起動し直さない" [ "$(count 'agent launch')" = 1 ]

setup "出し直しが、operationId の無い失敗を返す"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
echo '{"ok":false,"error":{"code":"reply_lost","data":{"operationId":"op_1"}}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
echo '{"ok":false,"error":{"code":"forbidden","message":"x"}}' >"$FAKE/launch.json"
run
check "失敗とは記録しない (最初の依頼が通っていないとは言えない)" lacks "$S/launches.tsv" "	fail	"
check "operationId を持ったまま残す" [ "$(cut -f2,3 "$S/launches.tsv" | tr '\t\n' '  ')" = "launching - lost op_1 launching op_1 lost op_1 " ]
run
check "次の回も、新しい起動ではなく同じ依頼を出し直す" [ "$(count '--retry-launch op_1')" = 2 ]
check "起動の呼び出しは 3 回 (新しい起動 1 + 出し直し 2)" [ "$(count 'agent launch')" = 3 ]
LAUNCH_UNKNOWN_AFTER=0 run
check "期限を過ぎたら出し直しをやめる" [ "$(count 'agent launch')" = 3 ]
check "人に上げる" called "自動の /sync-pr を起動できたか分からない: #1"

setup "出し直しを繰り返しても、期限は最初の時刻から数える"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
now=$(date +%s)
{
    printf '%s\tlaunching\t-\to/r#1\tsync-pr\tsha1\n' "$((now - 4000))"
    printf '%s\tlost\top_1\to/r#1\tsync-pr\tsha1\n' "$((now - 3990))"
    printf '%s\tlaunching\top_1\to/r#1\tsync-pr\tsha1\n' "$((now - 10))"
    printf '%s\tlost\top_1\to/r#1\tsync-pr\tsha1\n' "$((now - 9))"
} >"$S/launches.tsv"
run
check "出し直さない" no_launch
check "人に上げる" called "自動の /sync-pr を起動できたか分からない: #1"

setup "出し直しの途中で落ちた (launching <operationId> のまま)"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
now=$(date +%s)
{
    printf '%s\tlaunching\t-\to/r#1\tsync-pr\tsha1\n' "$((now - 60))"
    printf '%s\tlost\top_1\to/r#1\tsync-pr\tsha1\n' "$((now - 59))"
    printf '%s\tlaunching\top_1\to/r#1\tsync-pr\tsha1\n' "$((now - 30))"
} >"$S/launches.tsv"
run
check "同じ operationId で出し直す" called "--json --retry-launch op_1"

setup "返事を失った起動のあとに、PR の状態が変わる"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
echo '{"ok":false,"error":{"code":"reply_lost","data":{"operationId":"op_1"}}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
echo '{"ok":true}' >"$FAKE/launch.json"
echo 0 >"$FAKE/launch.json.rc"
: >"$FAKE/nodes"
pr 1 feat-a MERGEABLE FAILURE BLOCKED "" false sha-new
run
check "今の状態 (/fix-ci) ではなく、失った依頼 (/sync-pr) を出し直す" called "--prompt /sync-pr https://github.com/o/r/pull/1"
check "新しい対応はまだ起動しない" not_called "--prompt /fix-ci"
check "出し直しは同じ operationId" called "--json --retry-launch op_1"
check "失った依頼を起動済みにする" has "$S/dispatched.tsv" "o/r#1	sync-pr	sha1"

setup "結果は分からなかったが、この起動の指示を受け取ったエージェントが居る"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
: >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
t0=$(head -1 "$S/launches.tsv" | cut -f1)
: >"$FAKE/wts"
rm -rf "$(p a)"
wt a feat-a in-progress "$(agent done t1:l1 "/sync-pr https://github.com/o/r/pull/1 (pr-dispatch による自動起動 ${t0}。人は見ていない。)" 1000)"
run
check "起動し直さない" [ "$(count 'agent launch')" = 1 ]
check "起動できていたものとして覚える" has "$S/dispatched.tsv" "o/r#1	sync-pr	sha1"
check "記録も閉じる" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching launched " ]

setup "結果の分からない起動のあとに、人が同じ worktree で別のセッションを始めた"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
: >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
t0=$(head -1 "$S/launches.tsv" | cut -f1)
: >"$FAKE/wts"
rm -rf "$(p a)"
later=$(($(date +%s) * 1000 + 5000))
wt a feat-a in-progress "$(jq -cn --argjson at "$later" --arg old "/sync-pr https://github.com/o/r/pull/1 (pr-dispatch による自動起動 $((t0 - 500))。人は見ていない。)" \
    '[{state: "done", paneKey: "t1:l1", prompt: "別の作業をして", stateStartedAt: $at}, {state: "done", paneKey: "t2:l2", prompt: $old, stateStartedAt: $at}]')"
run
check "起動できた証拠にしない (起動の後に動いた別のセッションも、前の起動のエージェントも)" [ "$(cut -f2 "$S/launches.tsv" | tr '\n' ' ')" = "launching " ]
check "起動済みにしない" lacks "$S/dispatched.tsv" "o/r#1"
check "起動し直しもしない" [ "$(count 'agent launch')" = 1 ]

# ---- 再開したセッションを待つ ----
setup "再開のタブに、まだ指示が入っていない"
wt a feat-a in-progress "$(agent done t1:l1 "")"
wt b feat-b in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pr 2 feat-b CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1
term term_1 a | terms
run
check "その worktree には起動しない (エージェントは登録済みで done でも)" not_launched a
check "ほかの worktree には起動する" launched b
check "行は残る" has "$R/resume-pending.tsv" "term_1"

setup "再開のタブに指示が入った"
wt a feat-a in-progress "$(agent done t1:l1 続けて)"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1
term term_1 a | terms
run
check "行を消す" lacks "$R/resume-pending.tsv" "term_1"
check "解除した回は起動しない" not_launched a
run
check "次の回は、エージェントの状態で決まる (done なので起動する)" launched a

setup "同じ worktree の再開が 2 つあり、片方にだけ指示が入った"
wt a feat-a in-progress "$(jq -cn '[{state: "done", paneKey: "t1:l1", prompt: "続けて"}, {state: "done", paneKey: "t2:l2", prompt: ""}]')"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1
pending term_2 t2:l2 a sid-2
{ term term_1 a; term term_2 a; } | terms
run
run
check "起動しない" not_launched a
check "指示が入った方の行は消える" lacks "$R/resume-pending.tsv" "term_1"
check "入っていない方の行は残る" has "$R/resume-pending.tsv" "term_2"

setup "別のタブのエージェントに指示が入っている"
wt a feat-a in-progress "$(agent done t7:l7 人が打った指示)"
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1
term term_1 a | terms
run
run
check "解除しない" has "$R/resume-pending.tsv" "term_1"
check "起動しない" not_launched a

setup "再開のタブが閉じられた"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1
run
check "行を消す" lacks "$R/resume-pending.tsv" "term_1"
check "解除した回は起動しない" not_launched a
run
check "次の回は起動する" launched a

setup "端末の一覧が途中で切れている"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1
TRUNC=true terms </dev/null
run
run
check "タブが無いようには扱わない (行は残る)" has "$R/resume-pending.tsv" "term_1"
check "起動しない" not_launched a

setup "タブを作れたか分からない行"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending - - a sid-1
term term_other a | terms
run
run
check "その worktree に端末がある間は残る" has "$R/resume-pending.tsv" "sid-1"
check "起動しない" not_launched a
terms </dev/null
run
check "端末が 1 つも無くなったら消す" lacks "$R/resume-pending.tsv" "sid-1"
run
check "その次の回は起動する" launched a

setup "再開したセッションが始まらないまま 1 時間"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_1 t1:l1 a sid-1 "$(($(date +%s) - 4000))"
term term_1 a | terms
run
run
check "カードで 1 回だけ知らせる" [ "$(count '再開したセッションが始まらない')" = 1 ]
check "待ちは解かない" has "$R/resume-pending.tsv" "term_1"
check "起動しない" not_launched a

setup "再起動の直後: 再開が先、PR の対応は待つ"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
echo '{"type":"user","message":{"content":"続けて"}}' >"$base/t.jsonl"
printf 'BOOT-OLD\t1\tr::%s\t%s\t%s\n' "$(p a)" "$(p a)" "$base/t.jsonl" >"$R/sessions/sid-1"
term term_new a | terms
run
check "再開のタブを作る" called "terminal create --worktree id:r::$(p a)"
check "記録が残る" has "$R/resume-pending.tsv" "term_new	tabn:leafn"
check "同じ回に PR の対応は起動しない" not_launched a
run
check "指示が入るまで起動しない" not_launched a

setup "前の起動の印が残っている (DRY_RUN は再開しないので残る)"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
printf 'BOOT-OLD\t1\tr::%s\t%s\t%s\n' "$(p a)" "$(p a)" "$base/none.jsonl" >"$R/sessions/sid-1"
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "その worktree への起動を予定しない" [ -z "$(grep 'DRY-RUN: launch' "$base/out")" ]
check "待っている理由を出す" logged "再開したセッションに指示が入るのを待っている"

setup "DRY_RUN"
wt a feat-a in-progress
pr 1 feat-a CONFLICTING SUCCESS DIRTY
pending term_gone t1:l1 a sid-1
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "起動しない" no_launch
check "再開待ちの記録を書き換えない" has "$R/resume-pending.tsv" "term_gone"
check "起動の記録を書かない" [ ! -s "$S/launches.tsv" ]

# ---- worktree の無い PR に worktree を作る ----
# mainrepo: Orca に登録したリポの主 checkout を作る。origin は手元の bare リポジトリ
# (path に github.com/o/r を入れて、スクリプトが origin の URL から o/r を読めるようにする)。
M="$base/main/r"
mainrepo() {
    local o="$base/origin/github.com/o/r.git"
    git init -q --bare -b trunk "$o"
    git init -q -b trunk "$M"
    git -C "$M" remote add origin "$o"
    git -C "$M" commit -q --allow-empty -m init
    git -C "$M" push -q origin trunk
    jq -cn --arg p "$M" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/trunk", workspaceStatus: "", isMainWorktree: true, agents: [], repoId: "r"}' >>"$FAKE/wts"
}
# remote_branch <branch>: origin にだけある branch を作り、その head の SHA を出す。
remote_branch() {
    git -C "$M" switch -q -c "$1" trunk
    git -C "$M" commit -q --allow-empty -m "work on $1"
    git -C "$M" push -q origin "$1"
    git -C "$M" rev-parse HEAD
    git -C "$M" switch -q trunk
    git -C "$M" branch -q -D "$1"
}
adopt_config() { printf 'adopt_prs=true\nmax_worktrees=%s\n' "${1:-10}" >"$S/config"; }
created() { called "worktree create --repo path:$M --name pr-$1 "; }
not_created() { not_called "worktree create --repo path:$M --name pr-$1 "; }
no_create() { not_called "worktree create"; }

setup "worktree の無い PR に worktree を作る"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
run
check "exit 0" [ "$rc" = 0 ]
check "PR の head を base にして作る" called "worktree create --repo path:$M --name pr-1 --branch pr-1 --pr 1 --base-branch origin/feat-x --setup run --no-parent --json"
check "PR の branch に切り替わっている" [ "$(git -C "$ORCA_ROOT/r/pr-1" branch --show-current)" = feat-x ]
check "PR の head を指している" [ "$(git -C "$ORCA_ROOT/r/pr-1" rev-parse HEAD)" = "$sha" ]
check "仮のブランチは消す" [ -z "$(git -C "$M" branch --list pr-1)" ]
check "PR を結び付け直し、In review に置く" called "worktree set --worktree path:$ORCA_ROOT/r/pr-1 --pr 1 --workspace-status in-review --display-name r: PR の題名 1 --comment auto: PR #1 の対応のために worktree を作成 --json"
check "push できるように upstream を付ける" [ "$(git -C "$ORCA_ROOT/r/pr-1" rev-parse --abbrev-ref 'feat-x@{upstream}')" = origin/feat-x ]
check "記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created " ]
check "同じ回にはエージェントを起動しない" no_launch
check "検索に、登録したリポを入れる" called "repo:o/r"
cp "$FAKE/wts" "$FAKE/wts.before"
jq -cn --arg p "$ORCA_ROOT/r/pr-1" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/feat-x", workspaceStatus: "in-review", isMainWorktree: false, agents: [], repoId: "r", linkedPR: 1}' >>"$FAKE/wts"
run
check "次の回から、PR の対応が効く (setup script の無いリポは待たない)" launched pr-1
check "setup script が無いことを Orca に確かめる" called "repo show --repo path:$M --json"
check "ready を記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created ready " ]
check "もう 1 つは作らない" [ "$(count 'worktree create')" = 1 ]
# 人がその worktree を消した。
git -C "$M" worktree remove --force "$ORCA_ROOT/r/pr-1"
cp "$FAKE/wts.before" "$FAKE/wts"
run
check "一度作った PR には、worktree を人が消しても作り直さない" [ "$(count 'worktree create')" = 1 ]

# adopted <番号> <branch> <列>: 作った worktree を、Orca の一覧に出す (偽の Orca は一覧を自分では増やさない)。
adopted() {
    jq -cn --arg p "$ORCA_ROOT/r/pr-$1" --arg b "refs/heads/$2" --arg s "$3" '{worktreeId: ("r::" + $p), path: $p, branch: $b, workspaceStatus: $s, isMainWorktree: false, agents: [], repoId: "r", linkedPR: null}' >>"$FAKE/wts"
}
setup "作った worktree の setup が終わるまで、エージェントを起動しない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup && echo \"Orca setup done: ok\""}}}}}' >"$FAKE/repo.json"
run
check "作った時点では ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created " ]
adopted 1 feat-x in-review
term term_setup pr-1 | terms
echo '{"result":{"terminal":{"tail":["installing dependencies...","still running"]}}}' >"$FAKE/read.json"
run
run
check "setup の途中は起動しない" no_launch
check "端末の出力を読んで確かめる" called "terminal read --terminal term_setup --limit 200 --json"
echo '{"result":{"terminal":{"tail":["installing dependencies...","Orca setup done: ok"]}}}' >"$FAKE/read.json"
run
check "終わった印が出たら起動する" launched pr-1
check "ready を記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created ready " ]

setup "作った worktree の setup が、待っても終わらない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
run
cp "$FAKE/wts" "$FAKE/wts.before"
adopted 1 feat-x in-review
echo '{"ok":true,"result":{"warnings":["unknown status"]}}' >"$FAKE/set.json"
ADOPT_SETUP_WAIT=0 run
check "人に知らせられるまで、ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created " ]
echo '{"ok":true}' >"$FAKE/set.json"
ADOPT_SETUP_WAIT=0 run
check "人に上げる" called "PR #1: worktree の setup が終わったか確認できない"
check "その回は起動しない" no_launch
cp "$FAKE/wts.before" "$FAKE/wts"
adopted 1 feat-x needs-decision
run
check "Needs decision のあいだは起動しない" no_launch
cp "$FAKE/wts.before" "$FAKE/wts"
adopted 1 feat-x in-review
run
check "人がカードを戻したら起動する" launched pr-1

setup "setup script があるかを Orca から取れない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
run
adopted 1 feat-x in-review
: >"$FAKE/repo.json"
run
check "無いとは見なさない (起動しない)" no_launch
echo '{"ok":false,"error":{"code":"x"}}' >"$FAKE/repo.json"
run
check "失敗の返事でも、無いとは見なさない" no_launch
check "ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created " ]

setup "branch を切り替えたあと、記録を書く前に落ちた"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
printf '%s\tcreating\to/r#1\t%s\n' "$(/bin/date +%s)" "$sha" >"$S/adopts.tsv"
git -C "$M" fetch -q origin feat-x:feat-x
git -C "$M" worktree add -q "$ORCA_ROOT/r/pr-1" feat-x
adopted 1 feat-x in-progress
echo '{"result":{"terminal":{"tail":["installing dependencies..."]}}}' >"$FAKE/read.json"
term term_setup pr-1 | terms
run
check "setup が終わるまで起動しない" no_launch
check "もう 1 つは作らない" no_create
echo '{"result":{"terminal":{"tail":["Orca setup done: ok"]}}}' >"$FAKE/read.json"
run
check "終わった印が出たら起動する" launched pr-1

setup "作った worktree と DRY_RUN"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
run
adopted 1 feat-x in-review
echo '{"result":{"terminal":{"tail":["Orca setup done: ok"]}}}' >"$FAKE/read.json"
term term_setup pr-1 | terms
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "記録を書かない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating created " ]
check "起動を予定しない" [ -z "$(grep 'DRY-RUN: launch' "$base/out")" ]

setup "設定が無ければ作らない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
run
check "作らない" no_create
check "記録も作らない" [ ! -s "$S/adopts.tsv" ]
printf 'adopt_prs=false\nmax_worktrees=10\n' >"$S/config"
run
check "adopt_prs=false でも作らない" no_create
printf 'adopt_prs=true\n' >"$S/config"
run
check "max_worktrees が無ければ作らない" no_create

setup "worktree を作らない PR"
mainrepo
s1=$(remote_branch feat-1)
s2=$(remote_branch feat-2)
s3=$(remote_branch feat-3)
s4=$(remote_branch feat-4)
s5=$(remote_branch feat-5)
pr 1 feat-1 MERGEABLE SUCCESS CLEAN "" false "$s1"
PR_CREATED=2020-01-01 pr 2 feat-2 CONFLICTING SUCCESS DIRTY "" false "$s2"
PR_CROSS=true pr 3 feat-3 CONFLICTING SUCCESS DIRTY "" false "$s3"
PR_AUTHOR=someone pr 4 feat-4 CONFLICTING SUCCESS DIRTY "" false "$s4"
pr 5 feat-5 MERGEABLE SUCCESS BLOCKED "" true "$s5"
adopt_config
run
check "対応の要らない PR" not_created 1
check "作成から 30 日を超えた PR" not_created 2
check "fork からの PR" not_created 3
check "他人の PR" not_created 4
check "レビューを読み切れていない PR" not_created 5

setup "他人の PR には、worktree があってもエージェントを起動しない"
wt a feat-a in-progress
PR_AUTHOR=someone pr 1 feat-a CONFLICTING SUCCESS DIRTY
run
check "起動しない" no_launch

setup "worktree を作るのは 1 回に 1 つ"
mainrepo
s1=$(remote_branch feat-1)
s2=$(remote_branch feat-2)
pr 1 feat-1 CONFLICTING SUCCESS DIRTY "" false "$s1"
pr 2 feat-2 MERGEABLE FAILURE BLOCKED "" false "$s2"
adopt_config
run
check "1 つだけ作る" [ "$(count 'worktree create')" = 1 ]
run
check "次の回に、もう 1 つ" [ "$(count 'worktree create')" = 2 ]

setup "worktree が上限に達している"
mainrepo
wt a feat-a in-progress
sha=$(remote_branch feat-x)
pr 9 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config 1
run
check "作らない" no_create
adopt_config 2
run
check "上限を上げれば作る" created 9

setup "BRAKE のあいだは worktree を作らない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
: >"$S/BRAKE"
run
check "作らない" no_create

setup "DRY_RUN では worktree を作らない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "作らない" no_create
check "作る予定を出す" logged "DRY-RUN: adopt o/r#1"
check "記録しない" [ ! -s "$S/adopts.tsv" ]

setup "branch が Orca の外の checkout で使用中"
mainrepo
s1=$(remote_branch feat-1)
s2=$(remote_branch feat-2)
git -C "$M" worktree add -q "$base/other" -b feat-1 origin/feat-1
pr 1 feat-1 CONFLICTING SUCCESS DIRTY "" false "$s1"
pr 2 feat-2 CONFLICTING SUCCESS DIRTY "" false "$s2"
adopt_config
run
check "使用中の PR には作らない" not_created 1
check "同じ回に、次の PR を見る" created 2

setup "ローカルの branch が先行している (未 push のコミットがある)"
mainrepo
s1=$(remote_branch feat-1)
s2=$(remote_branch feat-2)
git -C "$M" branch -q feat-1 origin/feat-1
git -C "$M" switch -q feat-1
git -C "$M" commit -q --allow-empty -m "not pushed yet"
ahead=$(git -C "$M" rev-parse HEAD)
git -C "$M" switch -q trunk
pr 1 feat-1 CONFLICTING SUCCESS DIRTY "" false "$s1"
pr 2 feat-2 CONFLICTING SUCCESS DIRTY "" false "$s2"
adopt_config
run
check "作らない" not_created 1
check "ローカルの branch は動かさない" [ "$(git -C "$M" rev-parse feat-1)" = "$ahead" ]
check "見送ったと記録する" has "$S/adopts.tsv" "	refused	o/r#1	$s1"
check "同じ回に、次の PR を見る" created 2
run
check "head が変わるまで、試し直さない" [ "$(grep -c refused "$S/adopts.tsv")" = 1 ]

setup "ローカルの branch が分岐している"
mainrepo
s1=$(remote_branch feat-1)
git -C "$M" branch -q feat-1 trunk
git -C "$M" switch -q feat-1
git -C "$M" commit -q --allow-empty -m "diverged locally"
local_sha=$(git -C "$M" rev-parse HEAD)
git -C "$M" switch -q trunk
pr 1 feat-1 CONFLICTING SUCCESS DIRTY "" false "$s1"
adopt_config
run
check "作らない" no_create
check "ローカルの branch は動かさない" [ "$(git -C "$M" rev-parse feat-1)" = "$local_sha" ]

setup "ローカルの branch が遅れているだけなら、進めてから作る"
mainrepo
s1=$(remote_branch feat-1)
git -C "$M" branch -q feat-1 trunk
pr 1 feat-1 CONFLICTING SUCCESS DIRTY "" false "$s1"
adopt_config
run
check "作る" created 1
check "PR の head を指している" [ "$(git -C "$ORCA_ROOT/r/pr-1" rev-parse HEAD)" = "$s1" ]

setup "pr-<番号> という名前のブランチが既にある"
mainrepo
sha=$(remote_branch feat-x)
git -C "$M" switch -q -c pr-1 trunk
git -C "$M" commit -q --allow-empty -m "someone's own branch"
mine=$(git -C "$M" rev-parse HEAD)
git -C "$M" switch -q trunk
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
run
check "作る" created 1
check "元からあるブランチは消さない" [ "$(git -C "$M" rev-parse pr-1)" = "$mine" ]
check "Orca が付けた仮のブランチは消す" [ -z "$(git -C "$M" branch --list pr-1-2)" ]

setup "worktree を作ったあと、PR の branch に切り替えられない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
: >"$FAKE/create-then-block"
run
check "人に上げる" called "worktree set --worktree path:$ORCA_ROOT/r/pr-1 --comment PR #1 の取り込みが途中で止まった（branch が feat-x になっていない） --json --unread --workspace-status needs-decision"
check "作れたとは記録しない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating " ]

setup "前の回が、worktree を作ってから切り替えるまでの間で止まった"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
printf '%s\tcreating\to/r#1\t%s\n' "$(/bin/date +%s)" "$sha" >"$S/adopts.tsv"
git -C "$M" worktree add -q -b pr-1 "$ORCA_ROOT/r/pr-1" origin/feat-x
jq -cn --arg p "$ORCA_ROOT/r/pr-1" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/pr-1", workspaceStatus: "in-progress", isMainWorktree: false, agents: [], repoId: "r", linkedPR: null, linkedItems: [{provider: "github", type: "pr", number: 1}]}' >>"$FAKE/wts"
run
run
check "もう 1 つは作らない" no_create
check "自動では続けず、人に上げる (1 回だけ)" [ "$(count 'PR #1 の取り込みが途中で止まった')" = 1 ]
check "勝手に branch を切り替えない" [ "$(git -C "$ORCA_ROOT/r/pr-1" branch --show-current)" = pr-1 ]

setup "この PR に結び付いた worktree を、人が別の branch で作っている"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
git -C "$M" worktree add -q -b follow-up "$ORCA_ROOT/r/follow-up" trunk
jq -cn --arg p "$ORCA_ROOT/r/follow-up" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/follow-up", workspaceStatus: "in-progress", isMainWorktree: false, agents: [], repoId: "r", linkedPR: 1}' >>"$FAKE/wts"
run
check "作らない" no_create
check "カードには触らない" not_called "worktree set"

setup "worktree の作成が失敗を返す"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"ok":false,"error":{"code":"x"}}' >"$FAKE/create.json"
echo 1 >"$FAKE/create.json.rc"
run
run
run
run
check "3 回まで試す" [ "$(count 'worktree create')" = 3 ]

setup "worktree の作成の返事が読めない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
: >"$FAKE/create.json"
echo 1 >"$FAKE/create.json.rc"
run
run
check "作り直さない (作れていたら 2 つになる)" [ "$(count 'worktree create')" = 1 ]

[ "$fail" = 0 ] && echo "pr-dispatch: all checks passed"
exit "$fail"
