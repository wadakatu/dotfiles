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
    # 日本語の文中の変数は ${VAR} と書く。UTF-8 のロケールの bash は、変数名の直後の全角文字を名前の一部として読み、
    # set -u で落ちる。launchd とこのテストは C ロケールで動くので、実行しても見つからない (手で動かしたときだけ落ちる)。
    unbraced=$(grep -v '^[[:space:]]*#' "$root/home/scripts/$f.sh" | LC_ALL=C grep -cE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' || true)
    [ "$unbraced" = 0 ] || { echo "FAIL $f.sh: 全角文字の直前の変数が波括弧で囲まれていない ($unbraced 行)"; fail=1; }
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
# キューの issue の検索には issues.json、1 件の issue (check) には issue.json、draft を含む自分の open PR には
# prs.json と drafts.json (draft の PR を足すとき) を返す。
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE/calls"
[ -e "$FAKE/gh-down" ] && exit 1
case "$1 $2" in
    "api user") echo me ;;
    "api graphql")
        case "$*" in
            *is:closed*) [ -e "$FAKE/closed-down" ] && exit 1; cat "$FAKE/closed.tsv" ;;
            *is:issue*) [ -e "$FAKE/issues-down" ] && exit 1; cat "$FAKE/issues.json" ;;
            *"issue(number"*) [ -e "$FAKE/issue-down" ] && exit 1; cat "$FAKE/issue.json" ;;
            *draft:false*) cat "$FAKE/prs.json" ;;
            *) [ -e "$FAKE/open-down" ] && exit 1; cat "$FAKE/prs.json"; cat "$FAKE/drafts.json" 2>/dev/null || true ;;
        esac
        ;;
    "issue edit") [ -e "$FAKE/edit-fail" ] && exit 1; true ;;
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
    : >"$FAKE/issues"
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
    page <"$FAKE/issues" >"$FAKE/issues.json"
}
run() {
    render
    bash "$script" >"$base/out" 2>&1
    rc=$?
    # 途中で落ちた回 (未定義の変数など) も「何も起動しない」に見えるので、どの回も最後まで回ったことを確かめる。
    [ "$rc" = 0 ] || { echo "FAIL [$CASE] exit $rc: $(tail -n 1 "$base/out")"; fail=1; }
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

setup "同じ branch の PR が 2 本あり、1 本はマージできて、もう 1 本は conflict"
wt a feat-a in-review
pr 1 feat-a MERGEABLE SUCCESS CLEAN
pr 2 feat-a CONFLICTING SUCCESS DIRTY
run
check "マージできる PR はカードに書く" called "マージ可: #1"
check "同じ回に、conflict の PR には起動する (Needs decision に上げたのではない)" launched a

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
# remote_branch <branch> [orca.yaml の中身]: origin にだけある branch を作り、その head の SHA を出す。
remote_branch() {
    git -C "$M" switch -q -c "$1" trunk
    [ -z "${2:-}" ] || { printf '%b' "$2" >"$M/orca.yaml" && git -C "$M" add orca.yaml; }
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
check "記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created " ]
check "同じ回にはエージェントを起動しない" no_launch
check "検索に、登録したリポを入れる" called "repo:o/r"
cp "$FAKE/wts" "$FAKE/wts.before"
jq -cn --arg p "$ORCA_ROOT/r/pr-1" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/feat-x", workspaceStatus: "in-review", isMainWorktree: false, agents: [], repoId: "r", linkedPR: 1}' >>"$FAKE/wts"
run
check "次の回から、PR の対応が効く (setup script の無いリポは待たない)" launched pr-1
check "setup script が無いことを Orca に確かめる" called "repo show --repo id:r --json"
check "ready を記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created ready " ]
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
check "作った時点では ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created " ]
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
check "ready を記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created ready " ]

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
check "人に知らせられるまで、ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created " ]
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
check "ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created " ]

setup "setup が checkout の orca.yaml にだけある"
mainrepo
sha=$(remote_branch feat-x 'scripts:\n  setup: |\n    make setup\n')
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
run
check "orca.yaml ごと checkout されている" [ -s "$ORCA_ROOT/r/pr-1/orca.yaml" ]
adopted 1 feat-x in-review
term term_setup pr-1 | terms
echo '{"result":{"terminal":{"tail":["installing dependencies..."]}}}' >"$FAKE/read.json"
run
check "local に script が無くても、待つ" no_launch
check "ready にしない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created " ]
echo '{"result":{"terminal":{"tail":["Orca setup done: ok"]}}}' >"$FAKE/read.json"
run
check "終わった印が出たら起動する" launched pr-1

setup "orca.yaml はあるが、setup は書かれていない"
mainrepo
sha=$(remote_branch feat-x 'setupAgentStartupPolicy: wait-for-setup\ndefaultTabs:\n  - name: dev\n')
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
run
adopted 1 feat-x in-review
run
check "待たずに起動する" launched pr-1
run
check "ready は 1 回だけ記録する (次の回からは Orca に聞き直さない)" [ "$(grep -c "	ready	" "$S/adopts.tsv")" = 1 ]

setup "worktree を作ったあとで、作る設定を消した"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
run
adopted 1 feat-x in-review
rm "$S/config"
run
check "作った worktree の PR の対応は続ける (setup script の無いリポは待たない)" launched pr-1
check "新しくは作らない" [ "$(count 'worktree create')" = 1 ]

setup "同じ branch から base の違う PR を 2 本出している"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
pr 2 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
run
check "worktree は 1 つだけ作る" [ "$(count 'worktree create')" = 1 ]
adopted 1 feat-x in-review
term term_setup pr-1 | terms
echo '{"result":{"terminal":{"tail":["installing dependencies..."]}}}' >"$FAKE/read.json"
run
check "setup の途中は、どちらの PR にも起動しない" no_launch
echo '{"result":{"terminal":{"tail":["Orca setup done: ok"]}}}' >"$FAKE/read.json"
run
check "終わった印が出たら起動する" launched pr-1
check "ready は worktree に 1 回だけ記録する" [ "$(grep -c "	ready	o/r#1	-	$ORCA_ROOT/r/pr-1\$" "$S/adopts.tsv")" = 1 ]
check "もう 1 本の PR の名前では記録しない" [ -z "$(grep 'o/r#2' "$S/adopts.tsv")" ]

setup "同じ branch の PR が 2 本あり、setup が待っても終わらない"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
pr 2 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
run
adopted 1 feat-x in-review
ADOPT_SETUP_WAIT=0 run
check "人に上げる" called "worktree の setup が終わったか確認できない"
check "上げた回は、もう 1 本の PR にも起動しない" no_launch

setup "同じ branch の PR が 2 本あり、setup が待っても終わらず、もう 1 本はマージできる"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
run
adopted 1 feat-x in-review
pr 2 feat-x MERGEABLE SUCCESS CLEAN "" false "$sha"
ADOPT_SETUP_WAIT=0 run
check "人に上げる" called "worktree の setup が終わったか確認できない"
check "上げたカードを、同じ回に「マージ可」で In review に戻さない" not_called "マージ可: #2"

setup "branch を切り替えたあと、記録を書く前に落ちた"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"result":{"repo":{"hookSettings":{"scripts":{"setup":"make setup"}}}}}' >"$FAKE/repo.json"
# 作る前の行と、worktree が出来た直後の行 (path 付き) まで書かれている。
printf '%s\tcreating\to/r#1\t%s\t%s\n' "$(/bin/date +%s)" "$sha" "" "$(/bin/date +%s)" "$sha" "$ORCA_ROOT/r/pr-1" >"$S/adopts.tsv"
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
check "記録を書かない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating created " ]
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
check "作れたとは記録しない" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating creating " ]

setup "前の回が、worktree を作ってから切り替えるまでの間で止まった"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
printf '%s\tcreating\to/r#1\t%s\n' "$(/bin/date +%s)" "$sha" >"$S/adopts.tsv"
git -C "$M" worktree add -q -b pr-1 "$ORCA_ROOT/r/pr-1" origin/feat-x
jq -cn --arg p "$ORCA_ROOT/r/pr-1" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/pr-1", workspaceStatus: "in-progress", isMainWorktree: false, agents: [], repoId: "r", linkedPR: 1, linkedItems: [{provider: "github", type: "pr", number: 1}]}' >>"$FAKE/wts"
run
run
check "もう 1 つは作らない" no_create
check "自動では続けず、人に上げる (1 回だけ)" [ "$(count 'PR #1 の取り込みが途中で止まった')" = 1 ]
check "勝手に branch を切り替えない" [ "$(git -C "$ORCA_ROOT/r/pr-1" branch --show-current)" = pr-1 ]

setup "作成が失敗を返したが、worktree は出来ていた (応答待ちの時間切れ)"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
echo '{"ok":false,"error":{"code":"runtime_timeout"}}' >"$FAKE/create.json"
echo 1 >"$FAKE/create.json.rc"
run
check "失敗と記録する" [ "$(cut -f2 "$S/adopts.tsv" | tr '\n' ' ')" = "creating fail " ]
git -C "$M" worktree add -q -b pr-1 "$ORCA_ROOT/r/pr-1" origin/feat-x
jq -cn --arg p "$ORCA_ROOT/r/pr-1" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/pr-1", workspaceStatus: "in-progress", isMainWorktree: false, agents: [], repoId: "r", linkedPR: 1}' >>"$FAKE/wts"
run
run
check "試し直さない" [ "$(count 'worktree create')" = 1 ]
check "出来ていた worktree を人に上げる (1 回だけ)" [ "$(count 'PR #1 の取り込みが途中で止まった')" = 1 ]

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

setup "同じ worktree から出した前の PR (参照だけが残っている)"
mainrepo
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
adopt_config
# その worktree は、いまは別の branch で別の PR (2) の作業をしている。PR 1 は参照として残っているだけ。
git -C "$M" worktree add -q -b feat-next "$ORCA_ROOT/r/busy" trunk
jq -cn --arg p "$ORCA_ROOT/r/busy" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/feat-next", workspaceStatus: "in-progress", isMainWorktree: false, agents: [], repoId: "r", linkedPR: 2, linkedItems: [{provider: "github", type: "pr", number: 1}, {provider: "github", type: "pr", number: 2}]}' >>"$FAKE/wts"
run
check "worktree を失った PR として、作る" created 1

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

# ---- キュー: 自分がラベルを付けた自分の issue に worktree を作って worker を起動する ----
# ラベル名は何でもよい (実際の名前は追跡しない config にだけ書く)。T1 がラベルを付けた時刻。
LBL=q-label
T1=2026-01-02T00:00:00Z
T2=2026-01-03T00:00:00Z
queue_config() { printf 'queue_repos=o/r\nqueue_label=%s\nmax_worktrees=10\nmax_open_prs=10\nmax_per_day=5\n%b' "$LBL" "${1:-}" >"$S/config"; }
q_setup() { # q_setup <ケース名>: 主 checkout とキューの設定まで
    setup "キュー: $1"
    mainrepo
    queue_config
}
# issue <番号> [上書きする jq の式 ($t = T1、$l = ラベル名)]: キューのラベルを T1 に自分が付けた、自分の open issue
issue() {
    jq -cn --argjson n "$1" --arg l "$LBL" --arg t "$T1" '
        def conn($x): {pageInfo: {hasNextPage: false}, nodes: $x};
        {number: $n, title: ("Fix thing " + ($n | tostring)), state: "OPEN",
         createdAt: ("2025-12-01T00:00:" + (if $n < 10 then "0" else "" end) + ($n | tostring) + "Z"),
         lastEditedAt: null, author: {login: "me"}, editor: null,
         repository: {nameWithOwner: "o/r", defaultBranchRef: {name: "trunk"}},
         assignees: conn([]), labels: conn([{name: $l}]),
         labeled: conn([{createdAt: $t, actor: {login: "me"}, label: {name: $l}}]),
         comments: conn([]), blockedBy: conn([]), subIssuesSummary: {total: 0},
         closedByPullRequestsReferences: conn([]), xrefs: conn([])} | '"${2:-.}" >>"$FAKE/issues"
}
# qwt <名前> <issue の番号> <列> [エージェントの JSON 配列] [作成時刻] [branch]: キュー由来の worktree を Orca の一覧に出す
qwt() {
    wt "$1" "${6:-issue-$2-fix}" "$3" "${4:-[]}"
    tail -n 1 "$FAKE/wts" | jq -c --argjson n "$2" --argjson c "${5:-1}" '.linkedIssue = $n | .createdAt = $c' >"$FAKE/wts.last"
    sed '$d' "$FAKE/wts" >"$FAKE/wts.new" && cat "$FAKE/wts.last" >>"$FAKE/wts.new" && mv "$FAKE/wts.new" "$FAKE/wts"
}
# qcreated <番号> [列] [エージェントの JSON 配列]: 前の回に偽の Orca が作った worktree を、一覧に出す
qcreated() {
    jq -cn --arg p "$ORCA_ROOT/r/issue-$1-fix-thing-$1" --arg b "refs/heads/issue-$1-fix-thing-$1" --argjson n "$1" --arg s "${2:-in-progress}" --argjson a "${3:-[]}" \
        '{worktreeId: ("r::" + $p), path: $p, branch: $b, workspaceStatus: $s, isMainWorktree: false, agents: $a, repoId: "r", linkedIssue: $n, createdAt: 1}' >>"$FAKE/wts"
}
qkey() { printf 'o/r#%s\tissue-worker\t%s' "$1" "${2:-$T1}"; } # qkey <番号> [T]: launches.tsv のキー
qrow() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(qkey "$4" "${5:-$T1}")" >>"$S/launches.tsv"; } # qrow <時刻> <状態> <op> <番号> [T]
states() { cut -f2 "$S/launches.tsv" | tr '\n' ' '; }
q_created() { called "worktree create --repo path:$M --name issue-$1-"; }
q_launched() { called "--prompt /issue-worker $1 --approved-at ${2:-$T1}"; }
draft_pr() { # draft_pr <番号> <branch> <CI>: 自分の draft の PR (PR 対応の検索には出ない)
    jq -cn --argjson n "$1" --arg b "$2" --arg ci "$3" '{number: $n, isDraft: true, headRefName: $b, headRefOid: ("sha" + ($n | tostring)),
        author: {login: "me"}, repository: {nameWithOwner: "o/r"}, commits: {nodes: [{commit: {statusCheckRollup: {state: $ci}}}]}}' | page >>"$FAKE/drafts.json"
}

q_setup "ready な issue に worktree を作って worker を起動する"
issue 1
run
check "exit 0" [ "$rc" = 0 ]
check "検索は、自分の、ラベルの付いた open issue に絞る" called "is:issue is:open author:me label:\"$LBL\" repo:o/r"
check "worktree を既定ブランチから作る" called "worktree create --repo path:$M --name issue-1-fix-thing-1 --branch issue-1-fix-thing-1 --issue 1 --base-branch origin/trunk --setup run --no-parent --json"
check "カードに名前を付ける" called "--display-name r: #1 Fix thing 1 --json"
check "worker に T を渡して起動する" called "agent launch --agent claude --worktree path:$ORCA_ROOT/r/issue-1-fix-thing-1 --prompt /issue-worker 1 --approved-at $T1"
check "モデルと面を指定する" called "--json --model opus --effort high --surface chat"
check "指示に起動の印を入れる" grep -qF "pr-dispatch による自動起動 $(awk -F'\t' '$2 == "launching" { print $1 }' "$S/launches.tsv")。" "$FAKE/calls"
check "副作用の前後を記録する" [ "$(states)" = "creating launching launched " ]
check "起動できたらラベルを外す" called "gh issue edit 1 -R o/r --remove-label $LBL"

q_setup "ラベルを外す前に落ちた (launched の後)"
issue 1
qcreated 1 in-progress "$(agent working t1:l1 "/issue-worker 1")"
qrow 100 creating - 1
qrow 101 launching - 1
qrow 102 launched - 1
run
check "起動し直さない" no_launch
check "作り直さない" no_create
check "ラベルを外す" called "gh issue edit 1 -R o/r --remove-label $LBL"

q_setup "ラベルの履歴が欠けていれば、記録の続きもしない (見えている最後の T が、付け直した T とは限らない)"
issue 1 '.labeled.pageInfo.hasNextPage = true'
qcreated 1 in-progress "$(agent working t1:l1 "/issue-worker 1")"
qrow 100 creating - 1
qrow 101 launching - 1
qrow 102 launched - 1
run
check "ラベルを外さない" not_called "gh issue edit 1"
check "理由を出す" logged "queue 対象外 o/r#1 (内側の一覧が欠けている)"

# relabeled <番号>: T1 に付けたラベルを、T2 に自分が付け直した issue
relabeled() { issue "$1" '.labeled.nodes += [{createdAt: "'"$T2"'", actor: {login: "me"}, label: {name: $l}}]'; }
q_setup "ラベルを付け直しても、前の T の起動の結果が分かるまでは作らない (worktree が見えない)"
relabeled 1
qrow 100 creating - 1
qrow "$(date +%s)" launching - 1
run
check "作らない" no_create
check "起動しない" no_launch
check "前の起動は結果待ちのまま" [ "$(states)" = "creating launching " ]

q_setup "ラベルを付け直した: 前の T の起動を閉じた次の回に、新しい T で作る"
relabeled 1
qrow 100 creating - 1
qrow 101 launching - 1 # 待つ上限を過ぎている
run
check "この回は閉じるだけ" no_create
check "前の起動を unknown で閉じる" [ "$(states)" = "creating launching unknown " ]
run
check "次の回に作る" q_created 1
check "新しい T を渡す" q_launched 1 "$T2"

setup "キュー: 設定が無ければキューは無効"
mainrepo
wt a feat-a in-progress # worktree が無いと、キューの前に終わる回になって確かめられない
issue 1
run
check "issue を探さない" not_called "is:issue"
check "作らない" no_create
printf 'queue_label=%s\n' "$LBL" >"$S/config"
run
check "対象のリポが無ければ無効" not_called "is:issue"
printf 'queue_repos=o/r\n' >"$S/config"
run
check "ラベルが無ければ無効" not_called "is:issue"

# q_excluded <説明> <jq の式> <ログに出る理由> [config に足す行]
q_excluded() {
    q_setup "対象外: $1"
    [ -z "${4:-}" ] || printf '%s\n' "$4" >>"$S/config"
    issue 2
    issue 1 "$2"
    run
    check "worktree を作らない" not_created_issue 1
    check "その issue には起動しない" not_called "/issue-worker 1 "
    check "理由を出す" logged "queue 対象外 o/r#1 ($3)"
    check "ほかの ready な issue は作る" q_created 2
}
not_created_issue() { not_called "worktree create --repo path:$M --name issue-$1-"; }
q_excluded "他人がラベルを付けた" '.labeled.nodes[0].actor.login = "someone"' "ラベルを最後に付けたのが自分でない"
q_excluded "自分が付けたあと、他人が付け直した" '.labeled.nodes += [{createdAt: "2026-01-02T06:00:00Z", actor: {login: "someone"}, label: {name: $l}}]' "ラベルを最後に付けたのが自分でない"
q_excluded "T より後の本文の編集 (1 秒後)" '.lastEditedAt = "2026-01-02T00:00:01Z" | .editor = {login: "me"}' "ラベルの後に本文が編集された"
q_excluded "本文を最後に編集したのが他人 (T より前)" '.lastEditedAt = "2026-01-01T00:00:00Z" | .editor = {login: "someone"}' "本文を最後に編集したのが自分でない"
q_excluded "T より後に、それ以前の自分のコメントが編集された" '.comments.nodes = [{createdAt: "2026-01-01T00:00:00Z", lastEditedAt: "2026-01-02T00:00:01Z", author: {login: "me"}}]' "ラベルの後に、それ以前の自分のコメントが編集された"
q_excluded "no-agent" '.labels.nodes += [{name: "no-agent"}]' "no-agent"
q_excluded "ask のラベル" '.labels.nodes += [{name: "area: risky"}]' "ask のラベル" "ask_labels=other,area: risky"
q_excluded "ask の語" '.title = "本番の設定を直す"' "ask の語"
q_excluded "ask の語 (大文字小文字を区別しない)" '.title = "Rotate the SECRET"' "ask の語"
q_excluded "開いた blocker" '.blockedBy.nodes = [{state: "CLOSED"}, {state: "OPEN"}]' "開いている blocker がある"
q_excluded "子 issue" '.subIssuesSummary.total = 1' "子 issue がある"
q_excluded "閉じる PR (マージ済み)" '.closedByPullRequestsReferences.nodes = [{state: "CLOSED"}, {state: "MERGED"}]' "閉じる PR がある"
q_excluded "閉じる PR の参照 (open)" '.xrefs.nodes = [{willCloseTarget: true, source: {__typename: "PullRequest", state: "OPEN"}}]' "閉じる PR がある"
q_excluded "内側の一覧が欠ける (コメント)" '.comments.pageInfo.hasNextPage = true' "内側の一覧が欠けている"
q_excluded "内側の一覧が欠ける (blocker)" '.blockedBy.pageInfo.hasNextPage = true' "内側の一覧が欠けている"
q_excluded "内側の一覧が欠ける (ラベルの履歴)" '.labeled.pageInfo.hasNextPage = true' "内側の一覧が欠けている"
q_excluded "自分以外が assignee" '.assignees.nodes = [{login: "me"}, {login: "someone"}]' "自分以外が assignee"
q_excluded "author が他人" '.author.login = "someone"' "author が自分でない"
q_excluded "閉じている" '.state = "CLOSED"' "閉じている"
q_excluded "ラベルの履歴が無い (キー欠落)" 'del(.labeled.nodes[0].createdAt)' "ラベルを付けた時刻が分からない"

# q_ready <説明> <jq の式>: 止める理由に見えるが、止めないもの
q_ready() {
    q_setup "止めない: $1"
    issue 1 "$2"
    run
    check "worktree を作る" q_created 1
    check "worker を起動する" q_launched 1
}
q_ready "T より後のコメント (自分が書いて編集した) は仕様に入らない" '.comments.nodes = [{createdAt: "2026-01-02T00:00:01Z", lastEditedAt: "2026-01-02T00:00:09Z", author: {login: "me"}}]'
q_ready "他人のコメントが T より後に編集された" '.comments.nodes = [{createdAt: "2026-01-01T00:00:00Z", lastEditedAt: "2026-01-02T00:00:09Z", author: {login: "someone"}}]'
q_ready "本文の編集が T と同じ時刻" '.lastEditedAt = $t | .editor = {login: "me"}'
q_ready "本文の editor が null (T より前の編集)" '.lastEditedAt = "2026-01-01T00:00:00Z"'
q_ready "blocker が全部閉じている" '.blockedBy.nodes = [{state: "CLOSED"}]'
q_ready "閉じた PR と、閉じない参照だけ" '.closedByPullRequestsReferences.nodes = [{state: "CLOSED"}] | .xrefs.nodes = [{willCloseTarget: false, source: {__typename: "PullRequest", state: "OPEN"}}, {willCloseTarget: true, source: {__typename: "Issue"}}]'
q_ready "assignee が自分だけ" '.assignees.nodes = [{login: "me"}]'
q_ready "自分が付け直した (最後の時刻を T にする)" '.labeled.nodes = [{createdAt: "2025-12-30T00:00:00Z", actor: {login: "someone"}, label: {name: $l}}, {createdAt: $t, actor: {login: "me"}, label: {name: $l}}, {createdAt: "2026-01-02T05:00:00Z", actor: {login: "someone"}, label: {name: "other"}}]'

q_setup "題名が日本語でも、カードの名前を文字の途中で切らない"
issue 1 '.title = "ログイン画面の文言を直すログイン画面の文言を直すログイン画面の文言を直すログイン画面の文言を直す"'
run
check "branch は英数字の部分だけ (無ければ work)" q_created 1
check "branch の名前" called "--name issue-1-work --branch issue-1-work"
check "カードの名前は UTF-8 のまま" iconv -f UTF-8 -t UTF-8 "$FAKE/calls"

# Orca に worktree がある issue (linkedIssue・linkedItems の URL・branch の接頭辞) は ready にしない。
for how in linked url branch; do
    q_setup "worktree がある ($how)"
    issue 1
    case "$how" in
    linked) qwt other 1 in-progress "[]" 1 follow-up ;;
    url) wt other follow-up in-progress && jq -c '.linkedItems = [{type: "issue", url: "https://github.com/o/r/issues/1"}]' "$FAKE/wts" | tail -n 1 >"$FAKE/wts.last" &&
        { sed '$d' "$FAKE/wts"; cat "$FAKE/wts.last"; } >"$FAKE/wts.new" && mv "$FAKE/wts.new" "$FAKE/wts" ;;
    branch) wt other issue-1-by-hand in-progress ;;
    esac
    run
    check "作らない" no_create
    check "理由を出す" logged "queue 対象外 o/r#1 (Orca に worktree がある"
done

q_setup "古い順に、1 回に 1 件"
issue 1 # 検索の返す並びには頼らない (新しい方を先に返す)
issue 2 '.createdAt = "2025-11-01T00:00:00Z"'
run
check "古い方 (#2) を作る" q_created 2
check "1 回に 1 件" [ "$(count 'worktree create')" = 1 ]
run
check "次の回に、もう 1 件" q_created 1
check "合わせて 2 件" [ "$(count 'worktree create')" = 2 ]

q_setup "BRAKE"
issue 1
: >"$S/BRAKE"
run
check "作らない" no_create

q_setup "DRY_RUN"
issue 1
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "作らない" no_create
check "作る予定を出す" logged "DRY-RUN: queue worktree を作って worker を起動 → o/r#1"
check "記録しない" [ ! -s "$S/launches.tsv" ]
check "ラベルを外さない" not_called "issue edit"

# ---- キュー: 新しい着手を止める線 ----
q_setup "max_wip"
issue 1
qwt w5 5 in-progress                                   # PR が無い → 数える
qwt w6 6 in-review "$(agent done)"                     # PR があり、終わっている → 数えない
pr 60 issue-6-fix MERGEABLE SUCCESS BLOCKED
qwt w7 7 needs-decision "$(agent done)"                # PR があっても Needs decision → 数える
pr 70 issue-7-fix MERGEABLE SUCCESS BLOCKED
qwt w8 8 completed                                     # Done → 数えない
wt w9 issue-9-no-link in-progress                      # linkedIssue が無い → キュー由来ではない
qrow "$(date +%s)" creating - 4                        # 作成の結果待ちで worktree が見えない → 数える
queue_config 'max_wip=3\n'
run
check "3 つ占有で止める" no_create
check "理由を出す" logged "queue 見送り o/r#1 (max_wip (3/3))"
queue_config 'max_wip=4\n'
run
check "線を上げれば作る" q_created 1

q_setup "max_wip: PR があっても、エージェントが動いていれば数える"
issue 1
qwt w6 6 in-review "$(agent working)"
pr 60 issue-6-fix MERGEABLE SUCCESS BLOCKED
queue_config 'max_wip=1\n'
run
check "止める" no_create
check "理由を出す" logged "queue 見送り o/r#1 (max_wip (1/1))"

q_setup "max_per_day (今日の JST の creating を数える)"
issue 1
now=$(date +%s)
day0=$((now - (now + 32400) % 86400))
qrow "$((day0 - 1))" creating - 8
qrow "$((day0 - 1))" launched - 8
qrow "$day0" creating - 9
qrow "$day0" launched - 9
queue_config 'max_per_day=1\n'
run
check "今日 1 件で止める" no_create
check "理由を出す" logged "max_per_day (1/1)"
queue_config 'max_per_day=2\n'
run
check "昨日の分は数えない" q_created 1

q_setup "max_open_prs (draft と、worktree の無い PR も数える)"
issue 1
pr 50 feat-x MERGEABLE SUCCESS BLOCKED
draft_pr 51 feat-y SUCCESS
queue_config 'max_open_prs=2\n'
run
check "2 本で止める" no_create
check "理由を出す" logged "max_open_prs (2/2)"
queue_config 'max_open_prs=3\n'
run
check "線を上げれば作る" q_created 1

q_setup "max_worktrees"
issue 1
wt a feat-a in-progress
wt b feat-b in-progress
queue_config 'max_worktrees=2\n'
run
check "2 つで止める" no_create
queue_config 'max_worktrees=3\n'
run
check "線を上げれば作る" q_created 1

q_setup "max_worktrees: 同じ回に PR の取り込みで作った worktree も数える"
sha=$(remote_branch feat-x)
pr 1 feat-x CONFLICTING SUCCESS DIRTY "" false "$sha"
issue 1
queue_config 'adopt_prs=true\nmax_worktrees=1\n'
run
check "PR の worktree を作る" created 1
check "キューは作らない" not_created_issue 1
check "理由を出す" logged "queue 見送り o/r#1 (max_worktrees (1/1))"

q_setup "max_open_prs と max_worktrees を書いていなければ作らない"
issue 1
printf 'queue_repos=o/r\nqueue_label=%s\n' "$LBL" >"$S/config"
run
check "作らない" no_create

q_setup "自分の open PR (draft を含む) を取れない"
issue 1
: >"$FAKE/open-down"
run
check "作らない" no_create

q_setup "キューの issue を取れない"
issue 1
: >"$FAKE/issues-down"
run
check "exit 0" [ "$rc" = 0 ]
check "作らない" no_create

# ---- キュー: 副作用の途中で落ちた・結果が分からない ----
q_setup "worktree を作る前に落ちた (creating だけ)"
issue 1
issue 2
qrow "$(date +%s)" creating - 1
queue_config 'max_wip=1\n'
run
check "作り直さない" not_created_issue 1
check "結果待ちは枠を占有する (ほかの issue も作らない)" no_create

q_setup "worktree を作った後、起動の前に落ちた"
issue 1
qrow "$(date +%s)" creating - 1
qcreated 1
run
check "作り直さない" no_create
check "その worktree に worker を起動する" called "agent launch --agent claude --worktree path:$ORCA_ROOT/r/issue-1-fix-thing-1 --prompt /issue-worker 1 --approved-at $T1"
check "記録を続ける" [ "$(states)" = "creating launching launched " ]
check "ラベルを外す" called "gh issue edit 1 -R o/r --remove-label $LBL"

q_setup "worktree の作成の返事が読めない"
issue 1
: >"$FAKE/create.json"
echo 1 >"$FAKE/create.json.rc"
run
run
check "作り直さない (作れていたら 2 つになる)" [ "$(count 'worktree create')" = 1 ]
check "creating のまま" [ "$(states)" = "creating " ]

q_setup "worktree の作成が失敗を返す"
issue 1
echo '{"ok":false,"error":{"code":"x"}}' >"$FAKE/create.json"
echo 1 >"$FAKE/create.json.rc"
run
check "失敗を記録する" [ "$(states)" = "creating fail " ]
run
run
run
check "同じ T で 3 回まで" [ "$(count 'worktree create')" = 3 ]

q_setup "起動の前後で落ちた (launching の結果なし)"
issue 1
t0=$(($(date +%s) - 60))
qrow "$((t0 - 1))" creating - 1
qrow "$t0" launching - 1
qcreated 1
run
check "起動し直さない" no_launch
check "まだ人には上げない" not_called "起動できたか分からない"
# 同じ issue の指示でも、この起動の印が無いエージェント (人が始めたもの) は、起動できた証拠にしない。
: >"$FAKE/wts"
mainrepo_row() { jq -cn --arg p "$M" '{worktreeId: ("r::" + $p), path: $p, branch: "refs/heads/trunk", workspaceStatus: "", isMainWorktree: true, agents: [], repoId: "r"}' >>"$FAKE/wts"; }
mainrepo_row
qcreated 1 in-progress "$(agent done t1:l1 "/issue-worker 1 --approved-at $T1 (pr-dispatch による自動起動 $((t0 - 500))。)")"
run
check "印の違うエージェントでは閉じない" [ "$(states)" = "creating launching " ]
check "起動し直さない (エージェントが居る)" no_launch
: >"$FAKE/wts"
mainrepo_row
qcreated 1 in-progress "$(agent working t1:l1 "/issue-worker 1 --approved-at $T1 (pr-dispatch による自動起動 ${t0}。)")"
run
check "この起動の印のエージェントが居れば、起動できていた" [ "$(states)" = "creating launching launched " ]
check "ラベルを外す" called "gh issue edit 1 -R o/r --remove-label $LBL"
check "起動し直さない" no_launch

q_setup "起動の結果が分からないまま 30 分"
issue 1
t0=$(($(date +%s) - 60))
qrow "$((t0 - 1))" creating - 1
qrow "$t0" launching - 1
qcreated 1
LAUNCH_UNKNOWN_AFTER=0 run
check "人に上げる" called "--comment worker を起動できたか分からない: #1 --json --unread --workspace-status needs-decision"
check "閉じる" [ "$(states)" = "creating launching unknown " ]
check "起動し直さない" no_launch
LAUNCH_UNKNOWN_AFTER=0 run
check "その後も起動し直さない" no_launch
check "ラベルは外さない (起動できたか分からない)" not_called "issue edit"

q_setup "起動の返事を失う"
issue 1
echo '{"ok":false,"error":{"code":"reply_lost","data":{"operationId":"op_1"}}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
check "operationId を残す" [ "$(states)" = "creating launching lost " ]
check "ラベルは外さない" not_called "issue edit"
echo '{"ok":true}' >"$FAKE/launch.json"
echo 0 >"$FAKE/launch.json.rc"
qcreated 1
run
check "作り直さない" [ "$(count 'worktree create')" = 1 ]
check "同じ依頼を出し直す" called "--json --model opus --effort high --surface chat --retry-launch op_1"
check "出し直しの指示も同じ印" [ "$(grep -c "pr-dispatch による自動起動 $(awk -F'\t' '$2 == "launching" { print $1; exit }' "$S/launches.tsv")。" "$FAKE/calls")" = 2 ]
check "通ったらラベルを外す" called "gh issue edit 1 -R o/r --remove-label $LBL"

q_setup "起動が 3 回失敗する"
issue 1
echo '{"ok":false,"error":{"code":"x"}}' >"$FAKE/launch.json"
echo 1 >"$FAKE/launch.json.rc"
run
check "失敗を記録する" [ "$(states)" = "creating launching fail " ]
qcreated 1
run
run
check "作り直さず、同じ worktree で起動し直す" [ "$(count 'worktree create')" = 1 ]
check "3 回まで" [ "$(count 'agent launch')" = 3 ]
run
check "それ以上は起動しない" [ "$(count 'agent launch')" = 3 ]
check "人に上げる" called "--comment worker の起動に 3 回失敗: #1 --json --unread --workspace-status needs-decision"

q_setup "ラベルを外し損ねても、同じ T では起動しない"
issue 1
: >"$FAKE/edit-fail"
run
check "起動する" q_launched 1
run
check "同じ T では作り直さない (worktree を人が消していても)" [ "$(count 'worktree create')" = 1 ]
check "ラベルを外し直す" [ "$(count 'issue edit')" = 2 ]

q_setup "ラベルを付け直すと、新しい T で起動する (worktree が残っている間は起動しない)"
issue 1
run
: >"$FAKE/issues"
issue 1 '.labeled.nodes += [{createdAt: "2026-01-03T00:00:00Z", actor: {login: "me"}, label: {name: $l}}]'
qcreated 1 in-review
run
check "古い worktree が残っている間は作らない" [ "$(count 'worktree create')" = 1 ]
check "理由を出す" logged "queue 対象外 o/r#1 (Orca に worktree がある"
git -C "$M" worktree remove --force "$ORCA_ROOT/r/issue-1-fix-thing-1"
: >"$FAKE/wts"
mainrepo_row
run
check "消したら、新しい T で作る" [ "$(count 'worktree create')" = 2 ]
check "新しい T を渡す" q_launched 1 "$T2"

q_setup "同じ issue の worktree が 2 つ"
issue 1
qrow "$(date +%s)" creating - 1
qwt q1 1 in-progress "[]" 1
qwt q1b 1 in-progress "[]" 2 issue-1-again
run
check "古い方に起動する" called "agent launch --agent claude --worktree path:$(p q1) "
check "新しい方には起動しない" not_launched q1b
check "新しい方を人に上げる" called "worktree set --worktree path:$(p q1b) --comment 同じ issue の worktree が 2 つある。こちらは自動では使わない: #1 --json --unread --workspace-status needs-decision"

# q_step2 <ケース名>: worktree は作れたが、worker はまだ起動していない (creating の後)
q_step2() {
    q_setup "$1"
    issue 1
    qrow "$(date +%s)" creating - 1
}
q_step2 "worker を起動する前の worktree: BRAKE"
qcreated 1
: >"$S/BRAKE"
run
check "起動しない" no_launch
q_step2 "worker を起動する前の worktree: Needs decision"
qcreated 1 needs-decision
run
check "起動しない" no_launch
q_step2 "worker を起動する前の worktree: 再開したセッションを待っている"
qcreated 1
pending term_1 t1:l1 issue-1-fix-thing-1 sid-1
term term_1 issue-1-fix-thing-1 | terms
run
check "起動しない" no_launch
q_step2 "worker を起動する前の worktree: 起動していないのにエージェントが居る (人が始めた)"
qcreated 1 in-progress "$(agent done t1:l1 人が打った指示)"
run
check "起動しない" no_launch
check "ラベルも外さない" not_called "issue edit"
q_step2 "worker を起動する前の worktree: DRY_RUN"
qcreated 1
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "起動しない" no_launch
check "起動の予定を出す" logged "DRY-RUN: queue worker を起動 → o/r#1"

q_setup "起動に失敗したあと、worktree を人が消した"
issue 1
qrow 100 creating - 1
qrow 101 launching - 1
qrow 102 fail - 1
run
check "作り直さない (作成の失敗ではない)" no_create
check "起動もしない" no_launch

q_setup "作成の失敗と起動の失敗は別に数える"
issue 1
qrow 100 creating - 1
qrow 101 fail - 1
qrow 102 creating - 1
qrow 103 launching - 1
qrow 104 fail - 1
qrow 105 launching - 1
qrow 106 fail - 1
qcreated 1
run
check "起動の失敗はまだ 2 回なので、起動する" q_launched 1
check "人には上げない" not_called "起動に"

q_setup "結果の分からない起動を閉じる前に、ボードに書けない"
issue 1
t0=$(($(date +%s) - 60))
qrow "$((t0 - 1))" creating - 1
qrow "$t0" launching - 1
qcreated 1
echo '{"ok":true,"result":{"warnings":["unknown status"]}}' >"$FAKE/set.json"
LAUNCH_UNKNOWN_AFTER=0 run
check "人に知らせられるまで、記録は閉じない" [ "$(states)" = "creating launching " ]
check "起動し直さない" no_launch

q_setup "DRY_RUN では、外し損ねたラベルも外さない"
issue 1
qrow 100 creating - 1
qrow 101 launching - 1
qrow 102 launched - 1
render
DRY_RUN=1 bash "$script" >"$base/out" 2>&1
check "外さない" not_called "issue edit"
check "外す予定を出す" logged "DRY-RUN: queue ラベルを外す → o/r#1"

# ---- キュー由来の worktree のボード ----
setup "キュー: PR を出さずに終了 (キューを無効にしても、動いている分は知らせる)"
qwt q1 1 in-progress "$(agent done t1:l1 x 5000)"
qwt q2 2 in-progress "$(agent done t1:l1 x 5000)"
pr 20 issue-2-fix MERGEABLE SUCCESS BLOCKED
qwt q3 3 in-progress "$(agent working t1:l1 x "$(($(date +%s) * 1000))")"
qwt q4 4 needs-decision "$(agent done t1:l1 x 5000)"
qwt q5 5 in-progress
run
check "Needs decision に上げる" called "worktree set --worktree path:$(p q1) --comment PR を出さずに終了: #1 --json --unread --workspace-status needs-decision"
check "PR のある worktree は上げない" not_called "PR を出さずに終了: #2"
check "draft でない PR に「ready 判断」は付けない" not_called "ready 判断: #20"
check "動いているものは上げない" not_called "PR を出さずに終了: #3"
check "Needs decision のものは動かさない" not_called "PR を出さずに終了: #4"
check "エージェントがまだ居ない worktree は上げない" not_called "PR を出さずに終了: #5"
run
check "1 回だけ" [ "$(count 'PR を出さずに終了: #1')" = 1 ]

setup "キュー: クローズ済みの PR を読めない回は「PR を出さずに終了」を出さない (マージ済みと見分けられない)"
qwt q1 1 in-progress "$(agent done t1:l1 x 5000)"
: >"$FAKE/closed-down"
run
check "出さない" not_called "PR を出さずに終了"

setup "キュー: working のまま 2 時間更新が無い"
qwt q1 1 in-progress "$(agent working t1:l1 x "$((($(date +%s) - 7300) * 1000))")"
qwt q2 2 in-progress "$(agent working t1:l1 x "$((($(date +%s) - 7000) * 1000))")"
run
check "未読と「停止の疑い」(列は動かさない)" called "worktree set --worktree path:$(p q1) --comment 停止の疑い: #1（2 時間更新が無い） --json --unread"
check "2 時間たっていなければ付けない" not_called "停止の疑い: #2"

setup "キュー: draft の PR が終わって CI が緑 → ready 判断"
qwt q1 1 in-progress "$(agent done)"
draft_pr 31 issue-1-fix SUCCESS
qwt q2 2 in-progress "$(agent done)"
draft_pr 32 issue-2-fix FAILURE
qwt q3 3 in-progress "$(agent working t1:l1 x "$(($(date +%s) * 1000))")"
draft_pr 33 issue-3-fix SUCCESS
run
check "未読と「ready 判断」(列は動かさない)" called "worktree set --worktree path:$(p q1) --comment ready 判断: #31 --json --unread"
check "CI が緑でなければ付けない" not_called "ready 判断: #32"
check "エージェントが動いていれば付けない" not_called "ready 判断: #33"
check "draft は自動保守しない" no_launch

# ---- キュー: worker の着手前の再確認 (check) ----
# check_run <T>: worker の worktree で check を呼ぶ (リポは origin から取る)。
check_run() {
    jq -cn --slurpfile i "$FAKE/issues" '{data: {viewer: {login: "me"}, repository: {issue: ($i[0] // null)}}}' >"$FAKE/issue.json"
    (cd "$(p a)" && bash "$script" check 1 "$1") >"$base/out" 2>&1
    rc=$?
}
setup "check: 自分の起動の記録と worktree があり、ラベルが外れていても通る"
wt a issue-1-fix in-progress
printf 'queue_label=%s\n' "$LBL" >"$S/config"
issue 1 '.labels.nodes = []'
printf '%s\tlaunched\t-\t%s\n' "$(date +%s)" "$(qkey 1)" >"$S/launches.tsv"
ls -R "$STATE_ROOT" >"$base/state.before"
check_run "$T1"
check "exit 0" [ "$rc" = 0 ]
check "ok を出す" logged "ok"
check "1 件の issue を問い合わせる" called "-F n=1 -f owner=o -f name=r"
ls -R "$STATE_ROOT" >"$base/state.after"
check "状態を何も書かない (ロックも取らない)" cmp -s "$base/state.before" "$base/state.after"
check "Orca に触らない" not_called "orca "

setup "check: 止まる・確かめられない"
wt a issue-1-fix in-progress
printf 'queue_label=%s\n' "$LBL" >"$S/config"
issue 1 '.lastEditedAt = "2026-01-02T00:00:01Z"'
check_run "$T1"
check "T より後に編集されていれば exit 1" [ "$rc" = 1 ]
check "理由を出す" logged "ラベルの後に本文が編集された"
: >"$FAKE/issues"
issue 1
check_run "$T2"
check "その時刻に自分が付けたラベルが無ければ exit 1" [ "$rc" = 1 ]
: >"$FAKE/issues"
issue 1 '.labeled.nodes += [{createdAt: "2026-01-03T00:00:00Z", actor: {login: "someone"}, label: {name: $l}}]'
check_run "$T1"
check "あとで他人が付け直しても、渡された T の承認で進める" [ "$rc" = 0 ]
: >"$FAKE/issues"
check_run "$T1"
check "issue が無ければ exit 1" [ "$rc" = 1 ]
issue 1
: >"$FAKE/issue-down"
check_run "$T1"
check "GitHub に届かなければ exit 2" [ "$rc" = 2 ]
rm "$FAKE/issue-down"
rm "$S/config"
check_run "$T1"
check "設定が無ければ exit 2" [ "$rc" = 2 ]
(cd "$(p a)" && bash "$script" check 1) >"$base/out" 2>&1
check "T が無ければ exit 2" [ "$?" = 2 ]

[ "$fail" = 0 ] && echo "pr-dispatch: all checks passed"
exit "$fail"
