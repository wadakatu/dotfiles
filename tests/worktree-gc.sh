#!/usr/bin/env bash
# home/scripts/worktree-gc.sh の「消してよいか」の判定を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/worktree-gc.sh
# git は本物、orca / gh / docker / ps / stat / sysctl は偽物。lsof は本物 (lsof-cwd を置いたケースだけ偽物)。作業中の worktree を消さないことを主に見る。
# shellcheck disable=SC2016  # '...' の中の $x は偽コマンドや eval の変数
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/worktree-gc.sh"
# 呼び出し元の FF_CHECKOUTS は引き継がない (本物の git を使うので、export されていると一時ディレクトリの外の checkout が進む)。
unset FF_CHECKOUTS
base=$(mktemp -d)
base=$(cd "$base" && pwd -P) # macOS の /var → /private/var。lsof は実パスで返す
export GIT_CONFIG_GLOBAL="$base/gitconfig" GIT_CONFIG_NOSYSTEM=1 # 手元の hook や署名の設定を巻き込まない
git config -f "$GIT_CONFIG_GLOBAL" user.name t
git config -f "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
bg=""
trap '[ -n "$bg" ] && kill $bg 2>/dev/null; [ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}
logged() { grep -qF -- "$1" "$T/log"; }
exists() { [ -d "$1" ]; }
gone() { [ ! -d "$1" ]; }
not_called() { ! grep -q -- "-p $1 " "$T/docker-calls"; }

# ---- 偽のコマンド ----
mkdir -p "$base/bin"
# docker は docker-ps.tsv (project<TAB>working_dir) があるときだけ動いているふりをし、compose の呼び出しを記録する。
cat >"$base/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE/docker-ps.tsv" ] || exit 1
case "$1" in
    ps) case "$2" in
        -q) p=${4#label=com.docker.compose.project=}; awk -v p="$p" '$1 == p {print $2}' "$FAKE/docker-running" 2>/dev/null ;;
        *) cat "$FAKE/docker-ps.tsv" ;;
    esac ;;
    start) echo "$*" >>"$FAKE/order"; [ ! -f "$FAKE/start-fail" ] || exit 1 ;;
    compose) echo "$*" >>"$FAKE/docker-calls"; echo "$*" >>"$FAKE/order" ;;
    # volume ls は docker-volumes (project<空白>volume) から引く。volume-ls-fail があれば ls は失敗する。
    # 末尾のディスク回収 (prune) は docker-prune に書く。docker-calls と order に混ぜると、既存の呼び出し順の比較がずれる。
    volume) if [ "$2" = ls ]; then [ ! -f "$FAKE/volume-ls-fail" ] || exit 1; p=${5#label=com.docker.compose.project=}; awk -v p="$p" '$1 == p {print $2}' "$FAKE/docker-volumes" 2>/dev/null; else echo "$*" >>"$FAKE/docker-prune"; fi ;;
    image|builder) echo "$*" >>"$FAKE/docker-prune" ;;
    system) [ ! -f "$FAKE/df-fail" ] || exit 1 ;;
esac
exit 0
EOF
# gh は引数を gh-calls に控える。at-gh があれば、最初の呼び出しの時点でそれを 1 度だけ流す (判定の後に状態を変える継ぎ目)。
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/gh-calls"
if [ -f "$FAKE/at-gh" ]; then bash "$FAKE/at-gh"; rm -f "$FAKE/at-gh"; fi
cat "$FAKE/prs.json"
EOF
# worktree ps は呼ばれるたびに ps.<回数>.json を返す (無ければ ps.json、それも無ければ worktree 0 本)。ps-fail があれば失敗する。
# orca-unreachable があれば、ランタイムに届かないふりをする。
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "status --json")
        if [ -f "$FAKE/orca-unreachable" ]; then r=false; else r=true; fi
        echo "{\"result\": {\"runtime\": {\"reachable\": $r}}}" ;;
    "worktree ps")
        [ -f "$FAKE/ps-fail" ] && exit 1
        n=$(($(cat "$FAKE/ps-count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE/ps-count"
        # spawn-at-ps2 があれば、2 回目 (削除の直前) に、そこに書かれたパスを cwd にしたプロセスを起こす。
        if [ "$n" = 2 ] && [ -f "$FAKE/spawn-at-ps2" ]; then
            (cd "$(cat "$FAKE/spawn-at-ps2")" && exec sleep 60) >/dev/null 2>&1 &
            echo $! >"$FAKE/spawned.pid"
            sleep 1
        fi
        # lsof-at-ps2 があれば、2 回目に、その中身を偽の lsof の答え (lsof-cwd) に足す (中身が固定の偽の lsof には、起こしたプロセスは見えない)。
        if [ "$n" = 2 ] && [ -f "$FAKE/lsof-at-ps2" ]; then cat "$FAKE/lsof-at-ps2" >>"$FAKE/lsof-cwd"; fi
        if [ -f "$FAKE/ps.$n.json" ]; then cat "$FAKE/ps.$n.json"
        elif [ -f "$FAKE/ps.json" ]; then cat "$FAKE/ps.json"
        else echo '{"ok": true, "result": {"truncated": false, "totalCount": 0, "worktrees": []}}'; fi ;;
    # dirty-at-list / spawn-at-list があれば、一覧を返す前 ($REPO の節の判定の後、削除の前) に、そこに書かれたパスに
    # 未コミットのファイルを置く / そこを cwd にしたプロセスを起こす。
    "worktree list")
        [ ! -f "$FAKE/dirty-at-list" ] || touch "$(cat "$FAKE/dirty-at-list")/late.txt"
        if [ -f "$FAKE/spawn-at-list" ]; then
            (cd "$(cat "$FAKE/spawn-at-list")" && exec sleep 60) >/dev/null 2>&1 &
            echo $! >"$FAKE/spawned.pid"
            sleep 1
        fi
        cat "$FAKE/list.json" ;;
    "worktree rm")
        wt=${4#path:}; echo "$wt" >>"$FAKE/rm-calls"; echo "rm $wt" >>"$FAKE/order"
        [ -f "$FAKE/rm-fail" ] && { echo '{"ok": false}'; exit 0; }
        git -C "$FAKE/repo" worktree remove --force "$wt" && echo '{"ok": true}' ;;
    *) exit 1 ;;
esac
EOF
# 台帳の戻し方を流すテストで、本物の claude を起動しないための偽物。引数を記録するだけ。
cat >"$base/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/claude-calls"
EOF
# 通知は出さずに記録する (CI の ubuntu には osascript が無く、手元では本物の通知が出てしまう)。
cat >"$base/bin/osascript" <<'EOF'
#!/usr/bin/env bash
echo "${!#}" >>"$FAKE/notify-calls"
EOF
# lsof は lsof-cwd があるときだけ、cwd の問い合わせにその中身 (p<pid> と n<パス> の行) を返す。無ければ本物に渡す。
printf '#!/usr/bin/env bash\ncase " $* " in *" -d cwd "*) [ ! -f "$FAKE/lsof-cwd" ] || { cat "$FAKE/lsof-cwd"; exit 0; } ;; esac\nexec %q "$@"\n' \
    "$(command -v lsof)" >"$base/bin/lsof"
# ps・stat・sysctl は呼ばれた引数を <名前>-calls に控え、<名前>-fail があれば失敗し、無ければ置いた値を返す
# (CI の ubuntu には BSD の stat -f と kern.waketime が無い)。stat は stat-times の「<パス> <atime> <mtime>」の行から引く
# (「<パス> <作成時刻>」の 1 列の行は、-f %B の答えとしてその 1 つだけを返す)。
cat >"$base/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/ps-calls"; [ ! -f "$FAKE/ps-fail" ] || exit 1; cat "$FAKE/ps-out"
EOF
cat >"$base/bin/stat" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/stat-calls"; [ ! -f "$FAKE/stat-fail" ] || exit 1
awk -v f="${!#}" '$1 == f { print $2 (NF > 2 ? " " $3 : ""); n = 1 } END { exit !n }' "$FAKE/stat-times"
EOF
cat >"$base/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/sysctl-calls"; [ ! -f "$FAKE/sysctl-fail" ] || exit 1; cat "$FAKE/sysctl-out"
EOF
chmod +x "$base/bin/"*

# 毎回作り直す: origin (bare) と、それを clone した本体 $T/repo。
setup() {
    CASE=$1
    T="$base/$CASE"
    # 台帳と会話記録の置き場所。run_gc を通らない呼び出しもあるので、関数の引数でなく export で全部に継がせる。
    export STATE_ROOT="$T/state" CLAUDE_CONFIG_DIR="$T/claude"
    # scratchpad の worktree を探す場所。実機の scratchpad (このテストを流すセッションの作業ツリーも在る) を見ないよう、全部の呼び出しに継がせる。
    export SCRATCH_WT_GLOB="$T/tmp/*/*/scratchpad/wt/*"
    LEDGER="$T/state/cleanup-ledger/ledger.tsv"
    mkdir -p "$T/orca"
    # 「触らない」リストが無い回は何も消さないので、既存のケースは空のリスト (守るものが無い) で流す。
    # run_gc を通らない呼び出しが実機の ~/.config/cleanup-keep を読まないよう、ここで export する。
    # 変数名を KEEP にしないのは、一時ディレクトリを残すデバッグ用の KEEP=1 (先頭の trap) を上書きしないため。
    KEEPLIST="$T/keep"; export CLEANUP_KEEP="$KEEPLIST"
    : >"$KEEPLIST"
    git init -q --bare -b main "$T/origin.git"
    git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
    git -C "$T/repo" commit -q --allow-empty -m init
    git -C "$T/repo" push -q origin main
    git -C "$T/repo" remote set-head origin main
    echo '[]' >"$T/prs.json"
}
run_gc() { # run_gc [NAME=VALUE...]: 足した環境変数は既定を上書きする
    env PATH="$base/bin:$PATH" FAKE="$T" REPO="$T/repo" ORCA_ROOT="$T/orca" WORKTREE_GC_CONFIG=/nonexistent PROJECT_PREFIXES="proj-" "$@" \
        bash "$script" >"$T/log" 2>&1
    echo "exit=$?" >>"$T/log"
}
git_wt() { # git_wt <パス> <ブランチ>: 1 コミット載せて push し、upstream を付ける
    git -C "$T/repo" worktree add -q -b "$2" "$1" origin/main
    echo "$2" >"$1/f.txt"
    git -C "$1" add f.txt && git -C "$1" commit -q -m "change $2"
    git -C "$1" push -q -u origin "$2" 2>/dev/null
}
# $REPO の worktree: upstream を消して (= マージ済み) 24 時間より古く見せる。
merged_repo_wt() {
    git_wt "$1" "$2"
    git -C "$T/origin.git" branch -q -D "$2"
    touch -t 202601010000 "$1"
}
# Orca の worktree: PR #1 として push し、closedAt の PR と createdAt の ps を作る。
orca_wt() { # orca_wt <パス> <ブランチ> <PR closedAt> <worktree createdAt(ms)>
    git_wt "$1" "$2"
    git -C "$1" push -q origin "HEAD:refs/pull/1/head" 2>/dev/null
    jq -n --arg c "$3" '[{number: 1, state: "MERGED", closedAt: $c}]' >"$T/prs.json"
    jq -n --arg p "$1" --arg b "refs/heads/$2" '{result: {worktrees: [{path: $p, branch: $b, isMainWorktree: false}]}}' >"$T/list.json"
    ps_json "$1" "$4" done >"$T/ps.json"
}
ps_json() { # ps_json <パス> <createdAt> <エージェントの状態>
    jq -n --arg p "$1" --argjson c "$2" --arg s "$3" \
        '{ok: true, result: {truncated: false, totalCount: 1, worktrees: [{path: $p, createdAt: $c, agents: [{state: $s}]}]}}'
}
CREATED=1793000000000 # 2026-10-27
AFTER=2026-11-01T00:00:00Z
BEFORE=2026-10-01T00:00:00Z

# ---- $REPO: マージ済みで誰も使っていなければ消す ----
setup repo-merged
merged_repo_wt "$T/repo-wt" feat-a
run_gc
check "削除される" gone "$T/repo-wt"

# ---- $REPO: サブディレクトリに cwd を持つプロセスが居れば残す ----
setup repo-in-use
merged_repo_wt "$T/repo-wt" feat-a
mkdir -p "$T/repo-wt/sub"
touch -t 202601010000 "$T/repo-wt" # mkdir で新しくなったルートの mtime を戻す (24h ガードで残るのを避ける)
(cd "$T/repo-wt/sub" && exec sleep 60) &
bg=$!
sleep 1
run_gc
check "残る" exists "$T/repo-wt"
check "理由がログに出る" logged "cwd がこの中にあるプロセスが居る"
kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null; bg=""

# ---- $REPO: git status が失敗したら変更ありとみなす ----
setup repo-status-fails
merged_repo_wt "$T/repo-wt" feat-a
echo broken >"$(git -C "$T/repo-wt" rev-parse --git-dir)/index"
run_gc
check "残る" exists "$T/repo-wt"
check "理由がログに出る" logged "git status 失敗"

# ---- Orca: 作成後に閉じた PR で、固有コミットが無ければ消す ----
setup orca-merged
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
run_gc
check "orca rm が呼ばれる" grep -qxF "$T/orca/wt" "$T/rm-calls"

# ---- Orca: エージェントが done でも、cwd がこの中にあるプロセスが居れば残す ----
# ターンを終えて次の指示を待つセッションは done になる。PR をマージした直後に、その worktree で作業を続けることがある。
setup orca-live-session
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
(cd "$T/orca/wt" && exec sleep 60) &
bg=$!
sleep 1
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "cwd がこの中にあるプロセスが居る"
kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null; bg=""

# ---- Orca: 判定の後でプロセスが入ってきたら消さない ----
setup orca-in-use-at-rm
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo "$T/orca/wt" >"$T/spawn-at-ps2"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "削除直前に、cwd がこの中にあるプロセスを検出"
kill "$(cat "$T/spawned.pid" 2>/dev/null)" 2>/dev/null

# ---- Orca: ps が取れなければ、Orca の節ごと見送る ----
setup orca-ps-fails
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
touch "$T/ps-fail"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "orca worktree ps が取れない"

# ---- Orca: ps が行数上限で打ち切られていたら見送る ----
setup orca-ps-truncated
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
jq '.result.truncated = true' "$T/ps.json" >"$T/ps.tmp" && mv "$T/ps.tmp" "$T/ps.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"

# ---- Orca: worktree より前に閉じた同名ブランチの PR は根拠にしない ----
setup orca-old-pr
orca_wt "$T/orca/wt" feat-o "$BEFORE" "$CREATED"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "worktree の作成より前に閉じている"

# ---- Orca: 件名が同じでも中身の違う未 push のコミットは PR に無いとみなす ----
setup orca-amended
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo amended >"$T/orca/wt/f.txt"
git -C "$T/orca/wt" commit -q -a --amend -m "change feat-o"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "PR #1 に無いコミットあり"

# ---- Orca: 判定の後でエージェントが動き出したら消さない ----
setup orca-busy-at-rm
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
ps_json "$T/orca/wt" "$CREATED" working >"$T/ps.2.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "削除直前にエージェントが working"

# ---- Orca: PR が開いている・PR が無いなら残す ----
setup orca-pr-open
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo '[{"number": 1, "state": "OPEN", "closedAt": null}]' >"$T/prs.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: PR 進行中)"

setup orca-no-pr
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo '[]' >"$T/prs.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: PR 無し)"

# ---- Orca: worktree の作成時刻が整数でなければ、作成時刻の柵を素通りさせずに残す ----
created_not_int() { # created_not_int <ケース名> <createdAt (JSON の値)>
    setup "$1"
    orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
    jq --argjson c "$2" '.result.worktrees[0].createdAt = $c' "$T/ps.json" >"$T/ps.tmp" && mv "$T/ps.tmp" "$T/ps.json"
    run_gc
    check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
    check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: PR #1 が worktree の作成より前に閉じている、または日時が取れない)"
}
created_not_int orca-created-fraction 1793000000000.5
created_not_int orca-created-string '"2026-10-27"'

# ---- Orca: gh が成功で空の出力・JSON でない出力を返したら、PR を引けないとして残す ----
setup orca-gh-empty
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
: >"$T/prs.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: gh で PR を引けない)"

setup orca-gh-not-json
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo 'not json' >"$T/prs.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: gh で PR を引けない)"

# ---- Orca: 最後に PR の状態を読めなかったら、理由を出して残す ----
# PR の状態を読む jq だけを失敗させる偽物を前に差し込む。本物は、偽物の置き場所を PATH から外してから引く
# (`command -v jq` が shim を返す環境では、shim が PATH から引き直して偽物に戻り、終わらない)。
setup orca-pr-state-unreadable
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
mkdir -p "$T/bin"
cat >"$T/bin/jq" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"max_by(.number) | .state"*) exit 1 ;; esac
d=$(cd "$(dirname "$0")" && pwd)
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$d" | paste -sd: -)
exec jq "$@"
EOF
chmod +x "$T/bin/jq"
run_gc PATH="$T/bin:$base/bin:$PATH"
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: PR #1 の状態を読めない)"

# ---- Orca: PR の head はその worktree だけの ref に取り、FETCH_HEAD を書き換えない ----
# PR に無いコミットを持たせて worktree を残す (消すと FETCH_HEAD も ref も一緒に消えて、何も確かめられない)。
setup fetch-head-kept
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo amended >"$T/orca/wt/f.txt"
git -C "$T/orca/wt" commit -q -a --amend -m "change feat-o"
fh="$(git -C "$T/orca/wt" rev-parse --git-dir)/FETCH_HEAD"
echo marker >"$fh"
run_gc
check "PR の判定を通った (前提)" logged "keep  $T/orca/wt (feat-o: PR #1 に無いコミットあり)"
check "FETCH_HEAD が変わらない" test "$(cat "$fh")" = marker
check "PR の head をその worktree の ref に取った" git -C "$T/orca/wt" rev-parse --verify --quiet refs/worktree/gc/pr-head
check "本体の ref に出ない (名前で探す: 共有の ref に取った回も拾う)" test -z "$(git -C "$T/repo" for-each-ref | grep pr-head)"

# PR の head にだけ在るコミットを指す tag も、本体に連れてこない。コミットは別の clone で作る (本体にオブジェクトが在ると、
# ほかの fetch も tag を自動で連れてきて、PR の head の fetch を見分けられない)。
setup fetch-no-tags
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
git -C "$T/other" fetch -q origin refs/pull/1/head
git -C "$T/other" switch -q --detach FETCH_HEAD
git -C "$T/other" commit -q --allow-empty -m pr-only
git -C "$T/other" tag pr-tag
git -C "$T/other" push -q -f origin HEAD:refs/pull/1/head pr-tag 2>/dev/null
run_gc
check "PR の判定を通った (前提)" logged "STALE $T/orca/wt (feat-o: PR #1 が MERGED"
check "本体に tag が増えない" test -z "$(git -C "$T/repo" tag)"

# ---- Orca: origin が無く PR を引く先が分からなければ、空の名前で gh を呼ばずに残す (実行ごと止めない) ----
setup orca-no-origin
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
git -C "$T/repo" remote remove origin
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: gh で PR を引けない)"

# ---- Orca: PR の head を取れなかった回は、前の回に取った ref を読まずに「PR に無いコミットあり」で残す ----
setup fetch-fails-stale-ref
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
git -C "$T/orca/wt" update-ref refs/worktree/gc/pr-head HEAD
git -C "$T/origin.git" update-ref -d refs/pull/1/head
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (feat-o: PR #1 に無いコミットあり)"
check "本体の ref に出ない (名前で探す: 共有の ref に取った回も拾う)" test -z "$(git -C "$T/repo" for-each-ref | grep pr-head)"

# ---- $REPO: 判定の後 (Orca の節の途中) で未コミットの変更が入ったら、compose を止めずに残す ----
setup repo-recheck-dirty
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\t%s\n' wt-stack "$T/repo-wt/docker" >"$T/docker-ps.tsv"
echo "$T/repo-wt" >"$T/dirty-at-list"
run_gc
check "残る" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (削除直前に未コミットの変更を検出)"
check "compose を止めない" not_called wt-stack

# ---- $REPO: 判定の後でプロセスが入ってきたら消さない ----
setup repo-recheck-cwd
merged_repo_wt "$T/repo-wt" feat-a
echo "$T/repo-wt" >"$T/spawn-at-list"
run_gc
check "残る" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (削除直前に、cwd がこの中にあるプロセスを検出"
kill "$(cat "$T/spawned.pid" 2>/dev/null)" 2>/dev/null

# ---- $REPO: 削除の直前に lsof が取れなければ、使用中か分からないので残す ----
# 2 回目 (削除の直前) からの lsof だけを失敗させる偽物を前に差し込む (判定の前の 1 回目は本物に通す)。
setup repo-recheck-lsof-fails
merged_repo_wt "$T/repo-wt" feat-a
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nn=$(($(cat "$FAKE/lsof-count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE/lsof-count"\n[ "$n" -lt 2 ] || exit 1\nexec %q "$@"\n' \
    "$(command -v lsof)" >"$T/bin/lsof"
chmod +x "$T/bin/lsof"
run_gc PATH="$T/bin:$base/bin:$PATH"
check "lsof を 2 回以上呼んだ (前提)" test "$(cat "$T/lsof-count" 2>/dev/null)" -ge 2
check "残る" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (削除直前に、cwd がこの中にあるプロセスを検出、または lsof で取れない)"

# ---- compose: 消した worktree のものは名前を問わずボリュームごと、孤児は名前で絞ってボリュームを残す ----
setup compose
merged_repo_wt "$T/repo-wt" feat-a
mkdir -p "$T/infra"
printf '%s\t%s\n' custom-name "$T/repo-wt/docker" proj-old "$T/gone" other-old "$T/gone2" mysql "$T/infra" >"$T/docker-ps.tsv"
run_gc
check "消した worktree のプロジェクトは --volumes で落とす" grep -qxF "compose -p custom-name down --remove-orphans --volumes" "$T/docker-calls"
check "接頭辞の合う孤児はボリュームを残して落とす" grep -qxF "compose -p proj-old down --remove-orphans" "$T/docker-calls"
check "接頭辞の合わない孤児は触らない" not_called other-old
check "working_dir が健在のものは触らない" not_called mysql

# ---- Orca: worktree のスタックは削除の前に止め (コンテナは残す)、消せてからボリュームごと落とす ----
setup orca-stack
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
printf '%s\t%s\n' wt-stack "$T/orca/wt/docker" >"$T/docker-ps.tsv"
run_gc
check "削除の前に止め、削除の後でボリュームごと落とす" diff <(printf '%s\n' \
    "compose -p wt-stack stop" "rm $T/orca/wt" "compose -p wt-stack down --remove-orphans --volumes") <(head -n 3 "$T/order")

# ---- Orca: 削除が拒否されたら、止める前に動いていたコンテナだけ動かし直し、down はしない ----
setup orca-stack-rm-fails
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
printf '%s\t%s\n' wt-up "$T/orca/wt/a" wt-idle "$T/orca/wt/b" >"$T/docker-ps.tsv"
printf '%s %s\n' wt-up id-web >"$T/docker-running" # wt-up の他のサービスと wt-idle は元から止まっている
mkdir -p "$T/orca/wt/a" "$T/orca/wt/b" # 削除が拒否されたので working_dir は実在する
touch "$T/rm-fail"
run_gc
check "動いていたものだけ start し、どれも down しない" diff <(printf '%s\n' \
    "compose -p wt-idle stop" "compose -p wt-up stop" "rm $T/orca/wt" "start id-web") <(head -n 4 "$T/order")
check "down が呼ばれない" test -z "$(grep down "$T/docker-calls")"

# ---- $REPO: upstream が origin 以外の remote でも、消えたら拾う ----
setup repo-fork-upstream
git init -q --bare -b main "$T/upstream.git"
git -C "$T/repo" remote add upstream "$T/upstream.git"
git -C "$T/repo" worktree add -q -b feat-u "$T/repo-wt" origin/main
git -C "$T/repo-wt" push -q -u upstream feat-u 2>/dev/null
git -C "$T/upstream.git" branch -q -D feat-u
touch -t 202601010000 "$T/repo-wt"
run_gc
check "削除される" gone "$T/repo-wt"

# ---- $REPO: ignore されたファイルの件数をログに出す ----
setup repo-ignored
merged_repo_wt "$T/repo-wt" feat-a
echo .env >>"$T/repo/.git/info/exclude"
touch "$T/repo-wt/.env"
touch -t 202601010000 "$T/repo-wt"
run_gc
check "削除される" gone "$T/repo-wt"
check "件数がログに出る" logged "ignored 1 件も消える"

# ---- Orca: origin/HEAD が無くても、デフォルトブランチを補って判定する ----
setup orca-no-origin-head
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
# git 2.48 以降の fetch は origin/HEAD を自動で作る (remote.<name>.followRemoteHEAD=create)。それより古い git を再現する。
git -C "$T/repo" config remote.origin.followRemoteHEAD never
git -C "$T/repo" remote set-head origin --delete
run_gc
check "orca rm が呼ばれる" grep -qxF "$T/orca/wt" "$T/rm-calls"

# ---- Orca: detached で固有コミットが無く、作成から時間が経っていれば消す ----
setup orca-detached
git -C "$T/repo" worktree add -q --detach "$T/orca/wt" origin/main
jq -n --arg p "$T/orca/wt" '{result: {worktrees: [{path: $p, branch: null, isMainWorktree: false}]}}' >"$T/list.json"
ps_json "$T/orca/wt" "$CREATED" done >"$T/ps.json"
run_gc
check "orca rm が呼ばれる" grep -qxF "$T/orca/wt" "$T/rm-calls"

# ---- Orca: detached でもデフォルトブランチに無いコミットを持てば残す ----
setup orca-detached-commit
git -C "$T/repo" worktree add -q --detach "$T/orca/wt" origin/main
git -C "$T/orca/wt" commit -q --allow-empty -m local
jq -n --arg p "$T/orca/wt" '{result: {worktrees: [{path: $p, branch: null, isMainWorktree: false}]}}' >"$T/list.json"
ps_json "$T/orca/wt" "$CREATED" done >"$T/ps.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "detached: デフォルトブランチに無いコミット"

# ---- Orca: detached でも作ったばかりなら残す ----
setup orca-detached-new
git -C "$T/repo" worktree add -q --detach "$T/orca/wt" origin/main
jq -n --arg p "$T/orca/wt" '{result: {worktrees: [{path: $p, branch: null, isMainWorktree: false}]}}' >"$T/list.json"
ps_json "$T/orca/wt" "$(($(date +%s) * 1000))" done >"$T/ps.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"

# ---- 設定ファイル: 環境変数が無ければ REPO と BASE を読み、環境変数があればそちらが勝つ ----
setup config
git -C "$T/repo" worktree add -q --detach "$T/repo-wt" origin/main
touch -t 202601010000 "$T/repo-wt"
printf 'REPO=%q\nBASE=origin/nope\n' "$T/repo" >"$T/gc.env"
env PATH="$base/bin:$PATH" FAKE="$T" ORCA_ROOT="$T/orca" WORKTREE_GC_CONFIG="$T/gc.env" BASE=origin/main \
    bash "$script" >"$T/log" 2>&1
echo "exit=$?" >>"$T/log"
check "設定の REPO を使う" logged "repo=$T/repo "
check "環境変数の BASE が勝つ" gone "$T/repo-wt"

# ---- 設定ファイル: 空文字の環境変数でも接頭辞を上書きして、孤児を落とさない ----
setup config-empty-prefix
printf 'PROJECT_PREFIXES=proj-\n' >"$T/gc.env"
printf '%s\t%s\n' proj-old "$T/gone" >"$T/docker-ps.tsv"
env PATH="$base/bin:$PATH" FAKE="$T" REPO="$T/repo" ORCA_ROOT="$T/orca" WORKTREE_GC_CONFIG="$T/gc.env" PROJECT_PREFIXES= \
    bash "$script" >"$T/log" 2>&1
echo "exit=$?" >>"$T/log"
check "空の接頭辞なら孤児を落とさない" not_called proj-old

# ---- FF_CHECKOUTS: デフォルトブランチに居て遅れているだけの checkout を fast-forward する ----
advance() { git -C "$T/repo" commit -q --allow-empty -m up && git -C "$T/repo" push -q origin main; } # origin を 1 コミット進める
state() { git -C "$1" rev-parse HEAD main --abbrev-ref HEAD; } # HEAD・main・今のブランチ
at_origin() { [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$T/origin.git" rev-parse main)" ]; }
same() { [ "$(state "$1")" = "$2" ]; }
# ff_skip <名前> <準備するコマンド> <ログの理由>: clone を準備し、何も変わらず理由が 1 行出ることを見る
ff_skip() {
    setup "ff-$1"
    git clone -q "$T/origin.git" "$T/c" 2>/dev/null
    eval "$2"
    s=$(state "$T/c")
    run_gc FF_CHECKOUTS="$T/c"
    check "変わらない" same "$T/c" "$s"
    check "理由がログに出る" logged "ff-skip $T/c ($3"
}

setup ff-behind
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
run_gc FF_CHECKOUTS="$T/c"
check "origin に追いつく" at_origin "$T/c"
check "ログに出る" logged "ff    $T/c "

ff_skip other-branch 'advance; git -C "$T/c" switch -q -c other' "other はデフォルトブランチ main でない"
ff_skip detached 'advance; git -C "$T/c" switch -q --detach' "detached はデフォルトブランチ"
ff_skip dirty-tracked 'echo a >"$T/c/t.txt"; git -C "$T/c" add t.txt; git -C "$T/c" commit -q -m t; git -C "$T/c" push -q origin main; git -C "$T/repo" pull -q --ff-only; advance; echo b >"$T/c/t.txt"' "未コミットの変更あり"
ff_skip untracked 'advance; touch "$T/c/new.txt"' "未コミットの変更あり"
ff_skip cherry-pick 'advance; git -C "$T/c" rev-parse HEAD >"$T/c/.git/CHERRY_PICK_HEAD"' "git の操作の途中: CHERRY_PICK_HEAD"
ff_skip ahead 'git -C "$T/c" commit -q --allow-empty -m local' "origin/main に無いローカルコミット"
ff_skip diverged 'git -C "$T/c" commit -q --allow-empty -m local; advance' "origin/main に無いローカルコミット"
# git 2.48 以降の fetch は origin/HEAD を作り直すので、古い git と同じく作らない設定にする。
ff_skip no-origin-head 'advance; git -C "$T/c" config remote.origin.followRemoteHEAD never; git -C "$T/c" remote set-head origin -d' "origin/HEAD が無く"
ff_skip fetch-fails 'advance; git -C "$T/c" remote set-url origin "$T/nope.git"' "fetch 失敗"
check "掃除まで走り切る" logged "=== 完了"
ff_skip linked-worktree 'advance; rm -rf "$T/c"; git -C "$T/repo" worktree add -q -b lw "$T/c" main' ".git がディレクトリでない"

# ---- FF_CHECKOUTS: 1 つ目で見送っても 2 つ目は進める ----
setup ff-two
git clone -q "$T/origin.git" "$T/bad" 2>/dev/null
git -C "$T/bad" remote set-url origin "$T/nope.git"
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
run_gc FF_CHECKOUTS="$T/missing $T/bad $T/c"
check "2 つ目以降も進む" at_origin "$T/c"
check "掃除まで走り切る" logged "=== 完了"

# ---- FF_CHECKOUTS: DRY_RUN では進めず、成功のログも出さない ----
setup ff-dry-run
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
s=$(state "$T/c")
run_gc FF_CHECKOUTS="$T/c" DRY_RUN=1
check "変わらない" same "$T/c" "$s"
check "DRY-RUN がログに出る" logged "DRY-RUN: git -C $T/c merge --ff-only"
check "成功のログは出ない" test -z "$(grep -F "ff    " "$T/log")"

# ---- FF_CHECKOUTS / DRY_RUN: 環境変数が設定ファイルに勝つ (空文字も含む) ----
setup ff-env-wins
git clone -q "$T/origin.git" "$T/a" 2>/dev/null
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
s=$(state "$T/a")
printf 'FF_CHECKOUTS=%q\n' "$T/a" >"$T/gc.env"
run_gc WORKTREE_GC_CONFIG="$T/gc.env" FF_CHECKOUTS="$T/c"
check "環境変数の checkout だけ進む" at_origin "$T/c"
check "設定ファイルの checkout は触らない" same "$T/a" "$s"

setup ff-env-empty
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
s=$(state "$T/c")
printf 'FF_CHECKOUTS=%q\n' "$T/c" >"$T/gc.env"
run_gc WORKTREE_GC_CONFIG="$T/gc.env" FF_CHECKOUTS=
check "空の環境変数なら何もしない" same "$T/c" "$s"
check "ログも出ない" test -z "$(grep -E ' (ff-skip|ff    ) ' "$T/log")"

setup ff-env-dry-run
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
s=$(state "$T/c")
printf 'FF_CHECKOUTS=%q\nDRY_RUN=0\n' "$T/c" >"$T/gc.env"
run_gc WORKTREE_GC_CONFIG="$T/gc.env" DRY_RUN=1
check "環境変数の DRY_RUN が勝つ" same "$T/c" "$s"

# ---- FF_CHECKOUTS: REPO が無くても進め、掃除はしない ----
setup ff-no-repo
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
printf '%s\t%s\n' proj-old "$T/gone" >"$T/docker-ps.tsv"
run_gc REPO= FF_CHECKOUTS="$T/c"
check "進む" at_origin "$T/c"
check "repo が無いと出る" logged "repo が無い: "
check "docker を触らない" test ! -e "$T/docker-calls"

# ---- FF_CHECKOUTS: 確認と merge の間にブランチが変わったら WARN を出す ----
# merge の直前に other へ切り替える偽の git を前に差し込む。
setup ff-switched
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
git -C "$T/c" branch other
advance
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\ncase " $* " in *" merge --ff-only "*) %q -C %q switch -q other ;; esac\nexec %q "$@"\n' \
    "$(command -v git)" "$T/c" "$(command -v git)" >"$T/bin/git"
chmod +x "$T/bin/git"
run_gc FF_CHECKOUTS="$T/c" PATH="$T/bin:$base/bin:$PATH"
check "WARN が出る" logged "WARN: $T/c のブランチが確認の後で other に変わった"
check "成功のログは出ない" test -z "$(grep -F "ff    " "$T/log")"

# ---- 台帳: 消した worktree 1 本につき 1 行、戻し方と、そこに居たセッション。通知は 1 回の実行で 1 本 ----
# 列は 時刻 / 種類 / 対象 / 規則 / 戻し方 / 戻らないもの。
row() { awk -F'\t' -v p="$1" '$3 == p' "$LEDGER" 2>/dev/null; }                 # row <対象>: その対象の行
col_has() { row "$1" | cut -f"$2" | grep -qF -- "$3"; }               # col_has <対象> <列> <含む文字列>
col_starts() { row "$1" | cut -f"$2" | grep -q -- "^$3"; }            # col_starts <対象> <列> <先頭 (正規表現)>
rows() { [ "$(grep -c . "$LEDGER" 2>/dev/null)" = "$1" ]; }
notified_once() { [ "$(grep -c . "$T/notify-calls" 2>/dev/null)" = 1 ] && grep -qF -- "$1" "$T/notify-calls"; }
# 「戻し方」の列は、そのまま端末に貼って通るコマンドだけにする。空でない全行を bash と zsh の構文検査に通す。
# zsh は `(...)` を glob 修飾子として読んで構文では通すことがあるので、bash でも必ず見る。
restores_parse() {
    local c
    [ -s "$LEDGER" ] || return 0
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        bash -n -c "$c" || return 1
        if command -v zsh >/dev/null; then zsh -n -c "$c" || return 1; fi
    done < <(cut -f5 "$LEDGER")
}
session() { # session <worktree のパス> <ID>: Claude Code の規則でパスを変換した名前の下に会話記録を置く
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
    touch "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')/$2.jsonl"
}

setup ledger-repo
merged_repo_wt "$T/repo-wt" feat-a
session "$T/repo-wt" sess-0
session "$T/repo-wt" sess-1
touch -t 202601010000 "$CLAUDE_CONFIG_DIR/projects/"*/sess-0.jsonl # 古いほうの会話記録
git -C "$T/repo" worktree add -q --detach "$T/repo-det" origin/main
touch -t 202601010000 "$T/repo-det"
sha=$(git -C "$T/repo-wt" rev-parse HEAD)
det=$(git -C "$T/repo-det" rev-parse HEAD)
run_gc
check "消した 2 本で 2 行" rows 2
check "種類は worktree" col_has "$T/repo-wt" 2 worktree
check "規則にブランチと理由" col_has "$T/repo-wt" 4 "feat-a: upstream が remote から消滅"
check "戻し方は git worktree add -B" col_has "$T/repo-wt" 5 "cd $T/repo && git worktree add -B feat-a $T/repo-wt $sha"
check "戻し方に最後に書かれたセッションの再開" col_has "$T/repo-wt" 5 "cd $T/repo-wt && claude --resume sess-1"
check "ほかのセッションは先頭の : の注記に" col_starts "$T/repo-wt" 5 ": ほか 1 件は claude --resume の一覧から; cd "
check "detached は --detach で戻す" col_has "$T/repo-det" 5 "git worktree add --detach $T/repo-det $det"
check "detached の規則" col_has "$T/repo-det" 4 "detached: origin/main に含まれる"
check "Orca の外の節にはカードの注記が付かない" test -z "$(grep 'Orca のカード' "$LEDGER")"
check "通知は 1 本で、件数と種類" notified_once "worktree 2 件"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 無視されるファイルの件数とパスを「戻らないもの」に。多ければ先頭 20 件と残りの件数 ----
setup ledger-ignored
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\n' .env '*.log' >>"$T/repo/.git/info/exclude"
touch "$T/repo-wt/.env"
for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21; do touch "$T/repo-wt/x$i.log"; done
touch -t 202601010000 "$T/repo-wt"
run_gc
check "削除される" gone "$T/repo-wt"
check "件数" col_has "$T/repo-wt" 6 "無視されるファイル 22 件"
check "パス" col_has "$T/repo-wt" 6 ".env"
check "20 件目まで" col_has "$T/repo-wt" 6 "x19.log"
check "21 件目からは件数だけ" col_has "$T/repo-wt" 6 "ほか 2 件"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 会話記録のディレクトリ名が 200 字を超えるパスは、先頭 200 字で始まるディレクトリを探す ----
setup ledger-long-path
long="$T/$(printf 'b%.0s' $(seq 210))" # 1 階層は 255 バイトまで
merged_repo_wt "$long" feat-a
name=$(printf '%s' "$long" | sed 's/[^A-Za-z0-9]/-/g')
# hash の付け方は公開されていないので、区切りの無い形で置く (区切りを仮定していないことも見る)。
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$name" | cut -c1-200)1a2b3c"
touch "$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$name" | cut -c1-200)1a2b3c/sess-long.jsonl"
run_gc
check "長いパスでもセッションを拾う" col_has "$long" 5 "claude --resume sess-long"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 何も消さなかった回は、台帳にも通知にも出さない ----
setup ledger-nothing
git_wt "$T/repo-wt" feat-a # upstream 健在 = PR 進行中
touch -t 202601010000 "$T/repo-wt"
run_gc
check "残る" exists "$T/repo-wt"
check "台帳に行が無い" test ! -s "$LEDGER"
check "通知が出ない" test ! -e "$T/notify-calls"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 「一覧だけ」の予定 (plan-…) の行が在っても、何も消さなかった回は通知を出さない ----
setup ledger-nothing-plan
git_wt "$T/repo-wt" feat-a # upstream 健在 = PR 進行中
touch -t 202601010000 "$T/repo-wt"
mkdir -p "${LEDGER%/*}"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' 2026-11-01T00:00:00+0900 plan-worktree "$T/repo-wt" rule restore "" >"$LEDGER"
run_gc
check "残る" exists "$T/repo-wt"
check "台帳は予定の 1 行のまま" rows 1
check "通知が出ない" test ! -e "$T/notify-calls"

# ---- 台帳: DRY_RUN は台帳にも通知にも出さない ----
setup ledger-dry-run
merged_repo_wt "$T/repo-wt" feat-a
run_gc DRY_RUN=1
check "残る" exists "$T/repo-wt"
check "台帳に行が無い" test ! -s "$LEDGER"
check "通知が出ない" test ! -e "$T/notify-calls"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: Orca の worktree は PR 番号を規則に、カードが戻らないことを書く。消す前の stop は書かない (down で消えて戻せない) ----
setup ledger-orca-stack
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
printf '%s\t%s\n' wt-stack "$T/orca/wt/docker" >"$T/docker-ps.tsv"
printf '%s %s\n' wt-stack id-web >"$T/docker-running"
printf '%s %s\n' wt-stack wt-stack_db wt-stack wt-stack_cache >"$T/docker-volumes"
run_gc
check "規則に PR 番号" col_has "$T/orca/wt" 4 "feat-o: PR #1 が MERGED"
check "戻し方は本体で git worktree add -B" col_has "$T/orca/wt" 5 "cd $T/repo && git worktree add -B feat-o $T/orca/wt"
check "消える volume の名前" col_has "$T/orca/wt" 6 "wt-stack: wt-stack_db, wt-stack_cache"
check "down の行にも volume の名前" col_has wt-stack 6 "wt-stack_db, wt-stack_cache"
check "Orca のカードが戻らない旨" col_has "$T/orca/wt" 6 "Orca のカード"
check "down は compose-down の行" test -n "$(awk -F'\t' '$2 == "compose-down" && $3 == "wt-stack"' "$LEDGER" 2>/dev/null)"
check "stop の行は無い" test -z "$(awk -F'\t' '$2 == "compose-stop"' "$LEDGER" 2>/dev/null)"
check "worktree と down の 2 行だけ" rows 2
check "通知は 1 本で、種類ごとの件数" notified_once "compose-down 1 件、worktree 1 件"
check "通知に stop が入らない" test -z "$(grep compose-stop "$T/notify-calls" 2>/dev/null)"
check "down の戻し方は先頭がコマンド" col_starts wt-stack 5 ": worktree を戻してから; cd .* && docker compose -p wt-stack up -d$"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: HEAD の SHA を取れなければ、本体の HEAD から黙って作る git worktree add を書かない ----
# rev-parse --verify --quiet HEAD だけを失敗させる偽の git を前に差し込む (削除の経路はこれを使わない)。
setup ledger-no-sha
merged_repo_wt "$T/repo-wt" feat-a
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\ncase " $* " in *" rev-parse --verify --quiet HEAD "*) exit 1 ;; esac\nexec %q "$@"\n' \
    "$(command -v git)" >"$T/bin/git"
chmod +x "$T/bin/git"
run_gc PATH="$T/bin:$base/bin:$PATH"
check "削除される" gone "$T/repo-wt"
check "戻し方は注記だけ" test "$(row "$T/repo-wt" | cut -f5)" = ": HEAD を取れなかったので戻し方なし"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 削除が拒否されて戻した回は、stop も含めて何も書かず、通知も出さない (毎時同じ通知が出続けないため) ----
setup ledger-rm-fails
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
printf '%s\t%s\n' wt-up "$T/orca/wt/a" >"$T/docker-ps.tsv"
printf '%s %s\n' wt-up id-web >"$T/docker-running"
mkdir -p "$T/orca/wt/a" # 削除が拒否されたので working_dir は実在する (無いと孤児として落とされる)
touch "$T/rm-fail"
run_gc
check "台帳に行が無い" test ! -s "$LEDGER"
check "通知が出ない" test ! -e "$T/notify-calls"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 削除が拒否され、docker start も失敗した回は、止めたままのものを compose-stop の行に残す ----
setup ledger-start-fails
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
printf '%s\t%s\n' wt-up "$T/orca/wt/a" >"$T/docker-ps.tsv"
printf '%s %s\n' wt-up id-web wt-up id-db >"$T/docker-running"
mkdir -p "$T/orca/wt/a"
touch "$T/rm-fail" "$T/start-fail"
run_gc
check "compose-stop の 1 行だけ" rows 1
check "種類は compose-stop" col_has wt-up 2 compose-stop
check "戻し方は docker start と止めたコンテナの ID" test "$(row wt-up | cut -f5)" = "docker start id-web id-db"
check "通知が出る" notified_once "compose-stop 1 件"
check "戻し方が貼って通る" restores_parse

# ---- 台帳: 削除が途中で失敗して登録だけ外れた worktree は、控えた戻し方を worktree-remove-failed の行に残す ----
# ignore された書けないディレクトリがあると、git worktree remove は中身を消す途中で失敗し、登録は外す (実測)。
# root は書き込み権限を無視して消せてしまうので飛ばす。
if [ "$(id -u)" != 0 ]; then
    setup ledger-rm-broken
    merged_repo_wt "$T/repo-wt" feat-a
    echo locked/ >>"$T/repo/.git/info/exclude"
    mkdir -p "$T/repo-wt/locked/inner"
    touch "$T/repo-wt/locked/inner/f"
    chmod 555 "$T/repo-wt/locked/inner"
    touch -t 202601010000 "$T/repo-wt"
    sha=$(git -C "$T/repo-wt" rev-parse HEAD)
    run_gc
    chmod -R u+w "$T/repo-wt"
    check "登録が外れている (前提)" test -z "$(git -C "$T/repo" worktree list --porcelain | grep -F "$T/repo-wt")"
    check "種類は worktree-remove-failed" col_has "$T/repo-wt" 2 worktree-remove-failed
    check "戻し方は残ったフォルダを退けてから git worktree add" col_starts "$T/repo-wt" 5 ": 残ったフォルダを退けてから; cd .* && git worktree add -B feat-a .* $sha$"
    check "通知が出る" notified_once "worktree-remove-failed 1 件"
    check "戻し方が貼って通る" restores_parse
fi

# ---- 台帳: 削除が拒否されても worktree が壊れていなければ (lock など)、何も書かない ----
setup ledger-rm-locked
merged_repo_wt "$T/repo-wt" feat-a
git -C "$T/repo" worktree lock "$T/repo-wt"
touch -t 202601010000 "$T/repo-wt"
run_gc
check "残る" exists "$T/repo-wt"
check "台帳に行が無い" test ! -s "$LEDGER"
check "通知が出ない" test ! -e "$T/notify-calls"

# ---- 台帳: 削除が拒否された後で git worktree list 自体が失敗したら、壊れたとは書かない (分からないものを台帳に書かない) ----
# 削除を呼んだ後の worktree list だけを失敗させる偽の git を前に差し込む (候補を選ぶ一覧は通す)。
setup ledger-rm-list-fails
merged_repo_wt "$T/repo-wt" feat-a
git -C "$T/repo" worktree lock "$T/repo-wt"
touch -t 202601010000 "$T/repo-wt"
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash
case " $* " in
  *" worktree remove "*) touch "$FAKE/removed-once" ;;
  *" worktree list "*) [ ! -f "$FAKE/removed-once" ] || exit 1 ;;
esac
exec %q "$@"
' \
    "$(command -v git)" >"$T/bin/git"
chmod +x "$T/bin/git"
run_gc PATH="$T/bin:$base/bin:$PATH"
check "削除を呼んだ (前提)" test -e "$T/removed-once"
check "台帳に行が無い" test ! -s "$LEDGER"

# ---- 台帳: 名前付き volume の無い project には volume の注記を付けない。孤児の down はコンテナと匿名 volume が戻らない ----
setup ledger-compose
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\t%s\n' plain "$T/repo-wt/docker" proj-old "$T/gone" >"$T/docker-ps.tsv"
run_gc
check "worktree・down・孤児の down の 3 行 (前提)" rows 3
check "worktree の行に volume の注記が無い" test -z "$(row "$T/repo-wt" | cut -f6 | grep volume)"
check "down の行の戻らないものが空" test -z "$(row plain | cut -f6)"
check "孤児の down の戻らないものにコンテナ" col_has proj-old 6 "コンテナ"
check "孤児の down の戻らないものに匿名 volume" col_has proj-old 6 "匿名 volume"

# ---- 台帳: volume の名前を引けなかった回は、注記を落とさず「引けなかった」と書く ----
setup ledger-compose-vol-fails
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\t%s\n' wt-stack "$T/repo-wt/docker" >"$T/docker-ps.tsv"
printf '%s %s\n' wt-stack wt-stack_db >"$T/docker-volumes"
touch "$T/volume-ls-fail"
run_gc
check "worktree と down の 2 行 (前提)" rows 2
check "worktree の行に、引けなかった旨" col_has "$T/repo-wt" 6 "wt-stack: 名前を引けなかった"
check "down の行に、引けなかった旨" col_has wt-stack 6 "名前を引けなかった"

# ---- 台帳: docker system df が失敗しても、通知は出す (台帳に行があるのに知らせが無いのを避ける) ----
setup ledger-df-fails
merged_repo_wt "$T/repo-wt" feat-a
: >"$T/docker-ps.tsv"
touch "$T/df-fail"
run_gc
check "削除される" gone "$T/repo-wt"
check "通知が出る" notified_once "worktree 1 件"

# ---- 台帳: 戻し方の列をそのまま流すと worktree とブランチが戻り、セッションの再開まで通る (特殊文字を含むパスとブランチ) ----
setup ledger-restore-runs
wt="$T/w'&(1)"
merged_repo_wt "$wt" "feat/a'b&c"
session "$wt" sess-r
sha=$(git -C "$wt" rev-parse HEAD)
run_gc
check "削除される (前提)" gone "$wt"
env PATH="$base/bin:$PATH" FAKE="$T" bash -c "$(row "$wt" | cut -f5)" >"$T/restore.log" 2>&1
check "worktree が戻る" exists "$wt"
check "ブランチが戻る" test "$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null)" = "feat/a'b&c"
check "HEAD が戻る" test "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$sha"
check "セッションを再開する" grep -qxF -- "--resume sess-r" "$T/claude-calls"

# ---- 台帳: 値の中のタブと改行は空白にし、1 件を 1 行・6 列に保つ ----
setup ledger-escape
# shellcheck source=home/scripts/cleanup-ledger.sh
( . "$root/home/scripts/cleanup-ledger.sh" && ledger_add kind "$(printf 'a\tb')" "$(printf 'c\nd')" "$(printf 'e\rf')" lost )
check "1 行" rows 1
check "6 列" test "$(awk -F'\t' '{print NF}' "$LEDGER")" = 6
check "タブは空白に" test "$(cut -f3 "$LEDGER")" = "a b"
check "改行は空白に" test "$(cut -f4 "$LEDGER")" = "c d"
check "CR は空白に" test "$(cut -f5 "$LEDGER")" = "e f"
check "戻し方が貼って通る" restores_parse

# ---- 台帳の別名: 古い形 (列が 1 つ少ない) の行や空の列が混ざっても、どの行も同じ列数の表になる ----
# 別名は home/zsh.nix の shellAliases に 1 行で書いてある。その文字列を取り出して、HOME を一時ディレクトリにして流す。
setup ledger-alias
alias_cmd=$(sed -n "s/^ *cleanup-ledger = ''\(.*\)'';\$/\1/p" "$root/home/zsh.nix")
mkdir -p "$T/home/Library/Application Support/cleanup-ledger"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' 2026-11-01T00:00:00+0900 worktree /w/new rule-new restore-new lost-new \
    2026-11-01T01:00:00+0900 compose-down proj rule-down "" "" \
    >"$T/home/Library/Application Support/cleanup-ledger/ledger.tsv"
printf '%s\t%s\t%s\t%s\t%s\n' 2026-10-01T00:00:00+0900 worktree /w/old rule-old restore-old \
    >>"$T/home/Library/Application Support/cleanup-ledger/ledger.tsv"
HOME="$T/home" bash -c "$alias_cmd" >"$T/table" 2>&1
check "別名を zsh.nix から取り出せる" test -n "$alias_cmd"
check "3 行出る" test "$(grep -c . "$T/table")" = 3
check "どの行も 6 列" test "$(awk '{print NF}' "$T/table" | sort -u)" = 6
check "古い行の値が出る" grep -q '/w/old  *rule-old  *restore-old' "$T/table"

# ---- 台帳の別名: 「一覧だけ」の予定 (plan-…、戻らないものが空) の行が混ざっても、どの行も同じ列数 ----
setup ledger-alias-plan
mkdir -p "$T/home/Library/Application Support/cleanup-ledger"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' 2026-11-01T00:00:00+0900 worktree /w/new rule-new restore-new lost-new \
    2026-11-01T01:00:00+0900 plan-worktree /w/plan rule-plan restore-plan "" \
    >"$T/home/Library/Application Support/cleanup-ledger/ledger.tsv"
HOME="$T/home" bash -c "$alias_cmd" >"$T/table" 2>&1
check "2 行出る" test "$(grep -c . "$T/table")" = 2
check "どの行も 6 列" test "$(awk '{print NF}' "$T/table" | sort -u)" = 6
check "予定の行の値が出る" grep -q 'plan-worktree  */w/plan  *rule-plan  *restore-plan' "$T/table"

# ---- 「触らない」リスト: パスの行は、ほかの条件を全部満たす worktree も残す。区切りで比べる ----
kept() { logged "keep  $1 (「触らない」リスト)"; }
setup keep-path
merged_repo_wt "$T/pr-12" feat-a
merged_repo_wt "$T/pr-123" feat-b
echo "$T/pr-12" >"$KEEPLIST"
run_gc
check "リストの worktree は残る" exists "$T/pr-12"
check "理由がログに出る" kept "$T/pr-12"
check "/pr-12 の行は /pr-123 を守らない" gone "$T/pr-123"
check "戻し方が貼って通る" restores_parse

# ---- 「触らない」リスト: 行と対象を実体パスに揃えて比べる (/tmp/x の行が /private/tmp/x を守る形) ----
setup keep-symlink
mkdir -p "$T/real"
ln -s "$T/real" "$T/link"
merged_repo_wt "$T/real/wt" feat-a
echo "$T/link/wt/" >"$KEEPLIST"
run_gc
check "symlink 経由の行で実体の worktree が残る" exists "$T/real/wt"
check "理由がログに出る" kept "$T/real/wt"

# ---- 「触らない」リスト: Orca の worktree も残す ----
setup keep-orca
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
echo "$T/orca/wt" >"$KEEPLIST"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" kept "$T/orca/wt"

# ---- Orca でピン留めした worktree は、ほかの条件を全部満たしていても残す ----
setup keep-orca-pinned
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
jq '.result.worktrees[0].isPinned = true' "$T/ps.json" >"$T/ps.tmp" && mv "$T/ps.tmp" "$T/ps.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (Orca でピン留め)"

# ---- 判定の後でピン留めされたら消さない ----
setup keep-orca-pinned-at-rm
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
jq '.result.worktrees[0].isPinned = true' "$T/ps.json" >"$T/ps.2.json"
run_gc
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $T/orca/wt (削除直前に Orca でピン留め)"

# ---- 「触らない」リスト: 名前の行は compose project を止めない・落とさない。working_dir のパスの行も同じ ----
setup keep-compose
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\t%s\n' kept-stack "$T/repo-wt/docker" proj-old "$T/gone" proj-keep "$T/gone2" proj-dir "$T/gone3/x" >"$T/docker-ps.tsv"
printf '%s\n' kept-stack proj-keep "$T/gone3" >"$KEEPLIST"
run_gc
check "名前の行の project は stop も down もしない" not_called kept-stack
check "その project を持つ worktree は、止めずに丸ごと残す" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (compose kept-stack が「触らない」リスト)"
check "名前の行の孤児は down しない" not_called proj-keep
check "無いパスの行も文字どおりで比べ、その下の孤児を down しない" not_called proj-dir
check "リストに無い孤児は今どおり落とす" grep -qxF "compose -p proj-old down --remove-orphans" "$T/docker-calls"
check "戻し方が貼って通る" restores_parse

# ---- 「触らない」リストが無い回は、何も止めず何も消さず、通知は 1 日 1 回。FF_CHECKOUTS は進める ----
setup keep-missing
merged_repo_wt "$T/repo-wt" feat-a
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
printf '%s\t%s\n' wt-stack "$T/repo-wt/docker" proj-old "$T/gone" >"$T/docker-ps.tsv"
git clone -q "$T/origin.git" "$T/c" 2>/dev/null
advance
rm "$KEEPLIST"
run_gc FF_CHECKOUTS="$T/c"
check "worktree は残る" exists "$T/repo-wt"
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "compose を触らない" test ! -e "$T/docker-calls"
check "prune もしない" test ! -e "$T/docker-prune"
check "FF_CHECKOUTS は進む" at_origin "$T/c"
check "理由がログに出る" logged "WARN: 「触らない」リスト $T/keep が無いか読めない"
check "通知が 1 本" notified_once "「触らない」リスト"
run_gc
check "同じ日の 2 回目は通知しない" test "$(grep -c . "$T/notify-calls" 2>/dev/null)" = 1
check "2 回目も消さない" exists "$T/repo-wt"

# ---- 「触らない」リスト: 空行と # の行だけなら守るものが無いのと同じで、今までどおり消す ----
setup keep-blank
merged_repo_wt "$T/repo-wt" feat-a
mkdir -p "$T/infra"
printf '%s\t%s\n' mysql "$T/infra" >"$T/docker-ps.tsv"
printf '\n# 何も守らない\n   \n' >"$KEEPLIST"
run_gc
check "今までどおり消す" gone "$T/repo-wt"
check "prune も呼ぶ" test -s "$T/docker-prune"
check "通知は消した分だけ" notified_once "worktree 1 件"
check "戻し方が貼って通る" restores_parse

# ---- 「触らない」リスト: 守らない project が先に並んでも、守る project が同じ worktree に居れば 1 つも止めない ----
setup keep-compose-mixed
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\t%s\n' aaa-free "$T/repo-wt/a" zzz-kept "$T/repo-wt/z" >"$T/docker-ps.tsv"
echo zzz-kept >"$KEEPLIST"
run_gc
check "守らない project も止めない" not_called aaa-free
check "worktree は残る" exists "$T/repo-wt"
check "読めた行数がログに出る" logged "keep: パス 0 行・名前 1 行"

# ---- compose の project 名に空白があっても、1 つの名前のまま止める ----
setup keep-compose-space
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\t%s\n' "my proj" "$T/repo-wt/docker" >"$T/docker-ps.tsv"
run_gc
check "空白を含む名前のまま stop する" grep -qxF "compose -p my proj stop" "$T/docker-calls"
check "空白で割って stop しない" test -z "$(grep -xF -e "compose -p my stop" -e "compose -p proj stop" "$T/docker-calls")"

# ---- Docker に届かない回は、名前の行が 1 つでもあれば、中に守る project が居るか分からないので worktree を残す ----
setup keep-docker-down
merged_repo_wt "$T/repo-wt" feat-a
echo some-stack >"$KEEPLIST" # docker-ps.tsv が無いので、偽の docker は届かない
run_gc
check "worktree は残る" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (Docker に届かず"

setup keep-docker-down-paths
merged_repo_wt "$T/repo-wt" feat-a
echo "$T/elsewhere" >"$KEEPLIST"
run_gc
check "名前の行が無ければ今どおり消す" gone "$T/repo-wt"

# ---- 「触らない」リスト: 読めない行が 1 つでもあれば、その回は何も消さず、行番号をログに出して通知する ----
setup keep-bad-line
merged_repo_wt "$T/repo-wt" feat-a
printf '%s\n' "$T/other" "\$HOME/repo-wt" >"$KEEPLIST"
run_gc
check "worktree は残る" exists "$T/repo-wt"
check "行番号がログに出る" logged "2 行目"
check "通知が出る" notified_once "「触らない」リスト"

# ---- 「触らない」リスト: 大文字小文字を区別しないファイルシステムでは、綴りの違う行でも実在する worktree を守る ----
setup keep-case
mkdir -p "$T/CaseProbe"
if [ -d "$T/caseprobe" ]; then
    merged_repo_wt "$T/repo-wt" feat-a
    echo "$T/Repo-WT" >"$KEEPLIST"
    run_gc
    check "綴りの違う行でも残る" exists "$T/repo-wt"
fi

# ---- $REPO の節も Orca のピン留めを見る。Orca に届かない・ps が取れない回は、$REPO の節の削除も見送る ----
setup keep-repo-pinned
merged_repo_wt "$T/repo-wt" feat-a
ps_json "$T/repo-wt" "$CREATED" done | jq '.result.worktrees[0].isPinned = true' >"$T/ps.json"
run_gc
check "ピン留めした worktree は残る" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (Orca でピン留め)"

setup keep-repo-orca-unreachable
merged_repo_wt "$T/repo-wt" feat-a
touch "$T/orca-unreachable"
run_gc
check "Orca に届かない回は残る" exists "$T/repo-wt"
check "理由がログに出る" logged "keep  $T/repo-wt (Orca に届かず"

setup keep-repo-ps-fails
merged_repo_wt "$T/repo-wt" feat-a
touch "$T/ps-fail"
run_gc
check "ps が取れない回は残る" exists "$T/repo-wt"

# orca コマンドが無い環境では、ピン留めは無いものとして今どおり消す。スクリプトは PATH の後ろに /usr/local/bin などを
# 足すので、そこに本物の orca が在る環境 (手元の macOS) では、本物を呼ばないよう走らせない。
setup keep-repo-no-orca
merged_repo_wt "$T/repo-wt" feat-a
mkdir -p "$T/bin"
for c in docker gh osascript claude; do ln -s "$base/bin/$c" "$T/bin/$c"; done
noorca=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do [ -x "$d/orca" ] || printf '%s:' "$d"; done)
if ! (PATH="$T/bin:${noorca}/etc/profiles/per-user/${USER:-}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; command -v orca >/dev/null 2>&1); then
    env PATH="$T/bin:${noorca%:}" FAKE="$T" REPO="$T/repo" ORCA_ROOT="$T/orca" WORKTREE_GC_CONFIG=/nonexistent \
        bash "$script" >"$T/log" 2>&1
    echo "exit=$?" >>"$T/log"
    check "orca が無ければ今どおり消す" gone "$T/repo-wt"
    check "orca が無い枝を通った" logged "orca コマンドが無い"
else
    echo "skip [keep-repo-no-orca] 本物の orca が PATH の後ろに在る"
fi

# ---- 取り残された index.lock: リストに当たる worktree の lock は消さない ----
# git が動いていると掃除ごと見送るので、pgrep は「git は居ない」と返す偽物にする。
nogit_pgrep() { mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/bin/pgrep"; chmod +x "$T/bin/pgrep"; }
setup keep-lock
nogit_pgrep
git_wt "$T/kept-wt" feat-k
git_wt "$T/other-wt" feat-o # upstream 健在なので残る
echo "$T/kept-wt" >"$KEEPLIST"
for w in kept-wt other-wt; do touch "$T/repo/.git/worktrees/$w/index.lock"; touch -t 202601010000 "$T/repo/.git/worktrees/$w/index.lock"; done
run_gc PATH="$T/bin:$base/bin:$PATH"
check "リストの worktree の lock は残る" test -e "$T/repo/.git/worktrees/kept-wt/index.lock"
check "ほかの worktree の lock は消す" test ! -e "$T/repo/.git/worktrees/other-wt/index.lock"
check "理由がログに出る" logged "keep  index.lock $T/repo/.git/worktrees/kept-wt/index.lock (「触らない」リスト)"

# ---- 取り残された index.lock: gitdir が相対パス (git worktree add --relative-paths) でも、持ち主の worktree を引いて守る ----
# --relative-paths は git 2.48 から。知らない git では飛ばす (-h はリポジトリの中でないと使い方を出さない)。
setup keep-lock-relative
if git -C "$T/repo" worktree add -h 2>&1 | grep -q 'relative-paths'; then
    nogit_pgrep
    git -C "$T/repo" worktree add -q --relative-paths -b feat-k "$T/kept-wt" origin/main
    echo "$T/kept-wt" >"$KEEPLIST"
    touch "$T/repo/.git/worktrees/kept-wt/index.lock"
    touch -t 202601010000 "$T/repo/.git/worktrees/kept-wt/index.lock"
    run_gc PATH="$T/bin:$base/bin:$PATH"
    check "gitdir は相対パス (前提)" test -z "$(grep '^/' "$T/repo/.git/worktrees/kept-wt/gitdir")"
    check "リストの worktree の lock は残る" test -e "$T/repo/.git/worktrees/kept-wt/index.lock"
else
    echo "skip [keep-lock-relative] git が --relative-paths を知らない"
fi

# ---- 「無い」と「読めない行が在る」は別々に 1 日 1 回知らせる (無い → 作った → 書き間違い、でも 2 本目が出る) ----
setup keep-missing-then-bad
rm "$KEEPLIST"
run_gc
check "無い回に 1 本" test "$(grep -c . "$T/notify-calls" 2>/dev/null)" = 1
printf '%s\n' '$HOME/x' >"$KEEPLIST"
run_gc
check "同じ日でも、読めない行の回にもう 1 本" test "$(grep -c . "$T/notify-calls" 2>/dev/null)" = 2
check "2 本目は読めない行の知らせ" test -n "$(sed -n 2p "$T/notify-calls" | grep -F '読めない行')"
run_gc
check "読めない行の 2 回目は出ない" test "$(grep -c . "$T/notify-calls" 2>/dev/null)" = 2

# ---- 「触らない」リストが無い回の DRY_RUN は、通知も印も出さず、lock も消さない ----
setup keep-missing-dry-run
nogit_pgrep
merged_repo_wt "$T/repo-wt" feat-a
touch "$T/repo/.git/worktrees/repo-wt/index.lock"
touch -t 202601010000 "$T/repo/.git/worktrees/repo-wt/index.lock"
rm "$KEEPLIST"
run_gc DRY_RUN=1 PATH="$T/bin:$base/bin:$PATH"
check "通知が出ない" test ! -e "$T/notify-calls"
check "通知済みの印を書かない" test ! -e "$T/state/worktree-gc/keep-missing-warned"
check "lock を消さない" test -e "$T/repo/.git/worktrees/repo-wt/index.lock"
check "worktree は残る" exists "$T/repo-wt"

# ---- 「触らない」リストの関数: set -euo pipefail の下で source し、直接呼ぶ ----
setup keep-match
lib="$root/home/scripts/cleanup-ledger.sh"
# keep_load は読めた行数と読めない行をログに出すので、呼び側と同じく log を定義してから source する。
pre='set -euo pipefail; log() { echo "LOG $*"; }; . "$0"; '
mkdir -p "$T/home/w" "$T/real/x" "$T/real2/z"
ln -s "$T/real" "$T/link"
ln -s "$T/real2" "$T/link2"
printf '%s\n' '  # comment' '' '   ' \~/w "$T/link/x" "$T/gone/" ' name-a ' "$T/in/wt/data" "$T/real2/z" >"$KEEPLIST"
printf 'last-name' >>"$KEEPLIST" # 末尾に改行の無い最後の行
m() { HOME="$T/home" bash -c "$pre"'keep_load >/dev/null; keep_match "$@"' "$lib" "$@"; }
nm() { ! m "$@"; }
# agent-gc の形: 行が対象の中を指すとき (祖先の一致) は当てない。
m0() { HOME="$T/home" bash -c "$pre"'keep_load >/dev/null; keep_ancestors=0; keep_match "$@"' "$lib" "$@"; }
check "対象が symlink 経由で、行が実体パスでも当たる" m "$T/link2/z"
check "祖先の一致を切ると、行の上の対象には当たらない" eval '! m0 "$T/in/wt"'
check "祖先の一致を切っても、行そのものと行の下には当たる" m0 "$T/in/wt/data/x"
check "読めた行数をログに出す" test "$(HOME="$T/home" bash -c "$pre"'keep_load' "$lib" | grep -c 'LOG keep: パス 5 行・名前 2 行')" = 1
# APFS など大文字小文字を区別しないファイルシステムでは、綴りの違う行も同じディレクトリを指す。区別するか試して、しないときだけ見る。
mkdir -p "$T/CaseProbe"
if [ -d "$T/caseprobe" ]; then
    check "大文字小文字だけ違う対象にも当たる" m "$T/HOME/W"
    # symlink を通り、綴りも違う行は、組み込みの pwd -P の形 (symlink は解くが綴りはそのまま) でも持つ。
    # 持たないと、まだ無い対象 (消えた compose の working_dir など) を守らない。
    printf '%s\n' "$T/link/X" >"$T/case-keep"
    check "symlink を通り綴りの違う行が、まだ無い対象も守る" \
        env CLEANUP_KEEP="$T/case-keep" bash -c "$pre"'keep_load >/dev/null; keep_match "$1"' "$lib" "$T/real/X/gone-zz"
fi
# 読み違えると守ったつもりで守らないので、どれか 1 行でもあればリスト全体を読めないにする。
unreadable() { # unreadable <説明> <リストの中身 (printf の書式)>
    printf "$2" >"$T/bad-keep"
    check "$1 の行があれば読めない" env CLEANUP_KEEP="$T/bad-keep" bash -c "$pre"'! keep_load' "$lib"
}
unreadable '名前の行に /' 'proj\nw/sub\n'
unreadable '$ で始まる' '$HOME/w\n'
unreadable '" で始まる' '"/a/q"\n'
unreadable "' で始まる" "'/a/q'\n"
unreadable 'パスの行に空白 + #' '/a/keepme   # 大事\n'
unreadable '名前の行に空白 + #' 'proj # 大事\n'
unreadable '行の途中の CR' '/a/one\r/a/two\r'
# 2 行目以降の BOM は名前の行で見る (パスの行だと / を含む名前の行として別の枝で拾われ、BOM の検査が効いているか分からない)。
unreadable '2 行目以降の BOM' '/a/first\n\357\273\277proj\n'
unreadable '名前の行が ~ で始まる' '~user\n'
unreadable '名前の行に \\' 'C:\\Users\\x\n'
# 1 行目の BOM はエディタが付けるもので画面に見えないので、落として読み進める。
bom() { printf "$1" >"$T/bom-keep"; CLEANUP_KEEP="$T/bom-keep" bash -c "$pre"'keep_load >/dev/null && keep_match "$1"' "$lib" "$2"; }
check "1 行目の BOM を落としてパスの行を読む" bom '\357\273\277/a/bom\n' /a/bom/x
check "1 行目の BOM を落として名前の行を読む" bom '\357\273\277proj\n/a/x\n' proj
check "1 行目の BOM の後のコメントを読み飛ばす" bom '\357\273\277# c\n/a/x\n' /a/x
printf '/a/one\r/a/two\r' >"$T/cr-keep"
check "WARN が CR だけの改行を理由に挙げる" test "$(CLEANUP_KEEP="$T/cr-keep" bash -c "$pre"'keep_load || :' "$lib" | grep -c 'CR')" = 1
printf '/a/ok\n$ZZSECRET/x\n/a/ok2\nzzsecret/x\n' >"$T/bad-keep"
check "読めない行は行番号だけログに出す (中身は出さない)" test "$(CLEANUP_KEEP="$T/bad-keep" bash -c "$pre"'keep_load || :' "$lib" | grep -F '2, 4 行目' | grep -cvi 'zzsecret')" = 1
check "CRLF の行末は読める" env CLEANUP_KEEP="$T/crlf" bash -c 'printf "/a/x\r\nname\r\n" >"$CLEANUP_KEEP"; '"$pre"'keep_load' "$lib"
check "~other/x は名前の行で / を含むので読めない" env CLEANUP_KEEP="$T/tilde" bash -c 'printf "~other/x\n" >"$CLEANUP_KEEP"; '"$pre"'! keep_load' "$lib"
check "~ は HOME に展開する" m "$T/home/w/sub"
check "実体パスの対象に、symlink を通る行が当たる" m "$T/real/x"
check "無いパスの行は文字どおりで比べる" m "$T/gone/y"
check "名前は前後の空白を除いて完全一致" m name-a
check "名前は接頭辞では当たらない" nm name-ab
check "末尾に改行の無い最後の行も読む" m last-name
check "行が対象の中を指せば、対象ごと守る" m "$T/in/wt"
check "空行・空白だけ・# の行はどれにも当たらない" nm "$T/elsewhere"
check "名前の行はパスに当たらない" nm "$T/name-a"
check "複数の対象のどれかが当たれば守る" m nope "$T/real/x/y"
check "読まずに呼ぶと守る側に倒す" bash -c 'set -euo pipefail; . "$0"; keep_match /anything' "$lib"
rm "$KEEPLIST"
check "ファイルが無ければ読めない" bash -c 'set -euo pipefail; . "$0"; ! keep_load' "$lib"
mkdir "$KEEPLIST"
check "ディレクトリなら読めない" bash -c 'set -euo pipefail; . "$0"; ! keep_load' "$lib"
rmdir "$KEEPLIST"
if [ "$(id -u)" != 0 ]; then # root は読み取り権限を無視する
    : >"$KEEPLIST"
    chmod 000 "$KEEPLIST"
    check "読めなければ読めない" bash -c 'set -euo pipefail; . "$0"; ! keep_load' "$lib"
    chmod 600 "$KEEPLIST"
fi

# ---- 規則ごとのスイッチ: off / list / on。未設定と打ち間違いは off ----
setup rule-mode
rule() { env "$@" bash -c 'set -euo pipefail; log() { echo "LOG $*"; }; . "$0"; rule_mode x' "$lib" 2>"$T/err"; }
check "未設定は off" test "$(rule)" = off
check "on" test "$(rule RULE_x=on)" = on
check "list" test "$(rule RULE_x=list)" = list
check "off" test "$(rule RULE_x=off)" = off
check "空は off" test "$(rule RULE_x=)" = off
check "打ち間違いは off (標準出力は値だけ)" test "$(rule RULE_x=yes)" = off
check "打ち間違いは WARN を標準エラーに 1 行" test "$(grep -c 'WARN' "$T/err")" = 1
check "大文字は打ち間違い" test "$(rule RULE_x=ON)" = off
check "規則名に使えない文字は off" test "$(env bash -c 'set -euo pipefail; log() { :; }; . "$0"; rule_mode "a-b"' "$lib" 2>/dev/null)" = off

# ---- 「一覧だけ」の予定: ledger_plan は台帳に plan-<種類> の行を足し、同じ鍵は 1 度だけ書く ----
# plan <引数...>: set -euo pipefail の下で source して ledger_plan を呼び、戻り値を返す。呼び側と同じく || で受ける
# (直に呼ぶと、関数の中の失敗で set -e がシェルごと抜け、関数が返す値を見られない)。
plan() { bash -c 'set -euo pipefail; . "$0"; rc=0; ledger_plan "$@" || rc=$?; exit "$rc"' "$lib" "$@"; }
PLANNED() { echo "$T/state/cleanup-ledger/planned"; }
lines() { [ "$(grep -c '' "$1" 2>/dev/null)" = "$2" ]; }

setup plan-writes-one-row
plan k1 worktree /a/wt 規則 戻し方 ""
check "台帳が 1 行" rows 1
check "6 列" test "$(awk -F'\t' '{print NF}' "$LEDGER")" = 6
check "種類の列が plan-worktree" test "$(cut -f2 "$LEDGER")" = plan-worktree
check "対象・規則・戻し方の列" test "$(cut -f3-5 "$LEDGER")" = "/a/wt"$'\t'"規則"$'\t'"戻し方"
check "控えに k1 が 1 行" test "$(cat "$(PLANNED)")" = k1

setup plan-same-key-once
plan k1 worktree /a/wt 規則 戻し方 ""
plan k1 worktree /a/wt 規則 戻し方 ""
check "2 回目の戻り値も 0" test "$?" = 0
check "台帳は 1 行のまま" rows 1
check "控えも 1 行のまま" lines "$(PLANNED)" 1

setup plan-new-key-adds
plan k1 worktree /a/wt 規則 戻し方 ""
plan k2 worktree /a/wt 規則 戻し方 ""
check "鍵が違えば 2 行" rows 2
check "控えも 2 行" lines "$(PLANNED)" 2

# 鍵は行の完全一致・文字どおりで比べる。k1 は k11 に、a.b は aXb に当たらない。- で始まる鍵も引ける。
# 2 周呼んで 5 行のまま (部分一致・正規表現なら減り、- の鍵を引けなければ増える)。
setup plan-exact-key
for k in k11 k1 aXb a.b -k k11 k1 aXb a.b -k; do plan "$k" worktree /a/wt 規則 戻し方 ""; done
check "5 つの鍵で 5 行" rows 5
check "控えも 5 行" lines "$(PLANNED)" 5

# 引数が足りなくても、set -u で呼び側のシェルごと落とさず 1 を返す。
setup plan-few-args
check "引数 1 つは || で受けられ、次の行へ進む" test "$(bash -c 'set -euo pipefail; . "$0"; ledger_plan k || echo caught; echo next' "$lib" 2>/dev/null)" = "caught"$'\n'"next"
check "引数なしも同じ" test "$(bash -c 'set -euo pipefail; . "$0"; ledger_plan || echo caught; echo next' "$lib" 2>/dev/null)" = "caught"$'\n'"next"

setup plan-dry-run
DRY_RUN=1 plan k1 worktree /a/wt 規則 戻し方 ""
check "戻り値 0" test "$?" = 0
check "台帳が出来ない" test ! -e "$LEDGER"
check "控えが出来ない" test ! -e "$(PLANNED)"

setup plan-tab-newline
plan "$(printf 'k\t1\nx\ry')" worktree "$(printf '/a/w\tt\nz')" 規則 戻し方 ""
plan "$(printf 'k\t1\nx\ry')" worktree "$(printf '/a/w\tt\nz')" 規則 戻し方 ""
check "台帳は 1 行" rows 1
check "6 列のまま" test "$(awk -F'\t' '{print NF}' "$LEDGER")" = 6
check "控えも 1 行" lines "$(PLANNED)" 1
check "鍵のタブ・改行・CR は空白に" test "$(cat "$(PLANNED)")" = "k 1 x y"

setup plan-unwritable
if [ "$(id -u)" != 0 ]; then # root は書き込み権限を無視する
    mkdir -p "$T/ro"
    chmod 555 "$T/ro"
    STATE_ROOT="$T/ro" plan k1 worktree /a/wt 規則 戻し方 "" 2>/dev/null
    check "書けなければ戻り値 1" test "$?" = 1
    check "set -e の下で || true が落ちない" test "$(STATE_ROOT="$T/ro" bash -c 'set -euo pipefail; . "$0"; ledger_plan k1 worktree /a/wt r c "" 2>/dev/null || true; echo after' "$lib")" = after
    # 台帳は書けたが控えに書けない回も 1 (次の回は同じ予定をもう 1 行書く)。台帳を先に書くので、予定は台帳に残る。
    mkdir -p "$T/ro2/cleanup-ledger/planned"
    STATE_ROOT="$T/ro2" plan k1 worktree /a/wt 規則 戻し方 "" 2>/dev/null
    check "控えに書けなければ戻り値 1" test "$?" = 1
    check "控えに書けなくても台帳には 1 行書かれている" test "$(grep -c . "$T/ro2/cleanup-ledger/ledger.tsv" 2>/dev/null)" = 1
    chmod 755 "$T/ro"
fi

# ---- $REPO の prune: detached の HEAD がどの ref にも無い登録が在れば、リポごと prune を見送り、1 日 1 回知らせる ----
registered() { git -C "$T/repo" worktree list --porcelain | grep -qxF "worktree $1"; }
unregistered() { ! registered "$1"; }
gone_detached_unique() { # gone_detached_unique <パス>: どの ref にも無いコミットを HEAD に持つ detached の worktree を作り、フォルダだけ退ける
    git -C "$T/repo" worktree add -q --detach "$1" origin/main
    git -C "$1" commit -q --allow-empty -m unique
    u=$(git -C "$1" rev-parse HEAD)
    mv "$1" "$1.moved"
}
setup repo-prune-detached-unique
gone_detached_unique "$T/det"
run_gc
check "登録が残る" registered "$T/det"
check "見送りと SHA がログに出る" logged "keep  $T/repo (prune 見送り: $T/det の detached HEAD $u がどの ref にも無い)"
check "通知が 1 本" notified_once "prune"
run_gc
check "同じ日の 2 回目は通知しない" test "$(grep -c . "$T/notify-calls" 2>/dev/null)" = 1
check "2 回目も登録が残る" registered "$T/det"

setup repo-prune-detached-unique-dry-run
gone_detached_unique "$T/det"
run_gc DRY_RUN=1
check "見送りはログに出る" logged "prune 見送り: $T/det の detached HEAD $u"
check "通知が出ない" test ! -e "$T/notify-calls"
check "通知済みの印を書かない" test ! -e "$T/state/worktree-gc/prune-skipped-warned"

# ---- $REPO の prune: detached の HEAD が既定ブランチに在る登録と、ブランチの登録は今どおり外す ----
# フォルダの在る worktree は prune の対象でないので、固有のコミットを持つ detached でも prune を止めない。
setup repo-prune-detached-merged
git -C "$T/repo" worktree add -q --detach "$T/det" origin/main
git_wt "$T/brwt" feat-b
git -C "$T/repo" worktree add -q --detach "$T/live" origin/main
git -C "$T/live" commit -q --allow-empty -m live
mv "$T/det" "$T/det.moved"
mv "$T/brwt" "$T/brwt.moved"
run_gc
check "detached の登録が外れる" unregistered "$T/det"
check "ブランチの登録が外れる" unregistered "$T/brwt"
check "フォルダの在る worktree は残る" registered "$T/live"
check "見送りのログが出ない" test -z "$(grep 'prune 見送り' "$T/log")"
check "通知が出ない" test ! -e "$T/notify-calls"

# ---- $REPO の prune: HEAD がリモート追跡ブランチだけ・tag だけから辿れる登録も、見送らずに外す ----
setup repo-prune-remote-tag-only
git clone -q "$T/origin.git" "$T/other" 2>/dev/null
git -C "$T/other" switch -q -c side
git -C "$T/other" commit -q --allow-empty -m side
git -C "$T/other" push -q origin side 2>/dev/null
git -C "$T/repo" fetch -q origin
git -C "$T/repo" worktree add -q --detach "$T/det-remote" origin/side
git -C "$T/repo" worktree add -q --detach "$T/det-tag" origin/main
git -C "$T/det-tag" commit -q --allow-empty -m tagged
git -C "$T/det-tag" tag only-tag
check "ローカルのブランチには無い (前提)" test -z "$(git -C "$T/repo" branch --contains "$(git -C "$T/det-remote" rev-parse HEAD)")$(git -C "$T/repo" branch --contains "$(git -C "$T/det-tag" rev-parse HEAD)")"
mv "$T/det-remote" "$T/det-remote.moved"
mv "$T/det-tag" "$T/det-tag.moved"
run_gc
check "リモート追跡ブランチだけから辿れる登録が外れる" unregistered "$T/det-remote"
check "tag だけから辿れる登録が外れる" unregistered "$T/det-tag"
check "見送りのログが出ない" test -z "$(grep 'prune 見送り' "$T/log")"

# ---- $REPO の prune: 登録の一覧を取れない回は、何が外れるか分からないので prune しない ----
# 2 回目 ($REPO の判定の一覧の次、prune の前の確認) からの git worktree list だけを失敗させる偽物を前に差し込む。
setup repo-prune-list-fails
git -C "$T/repo" worktree add -q --detach "$T/det" origin/main
mv "$T/det" "$T/det.moved"
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash
case " $* " in
  *" worktree list "*) n=$(($(cat "$FAKE/wtlist-count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE/wtlist-count"; [ "$n" -lt 2 ] || exit 1 ;;
esac
exec %q "$@"
' \
    "$(command -v git)" >"$T/bin/git"
chmod +x "$T/bin/git"
run_gc PATH="$T/bin:$base/bin:$PATH"
check "一覧を 2 回以上呼んだ (前提)" test "$(cat "$T/wtlist-count" 2>/dev/null)" -ge 2
check "登録が残る" registered "$T/det"
check "理由がログに出る" logged "keep  $T/repo (prune 見送り: git worktree list が失敗)"
check "通知は出さない" test ! -e "$T/notify-calls"

# ---- $REPO の prune: worktree list に prunable で出ない登録 (gitdir が無い・空、同じパスの重複) も、prune が外すなら見る ----
# どれも worktree list --porcelain からは見えないので、登録が残ったかは $GIT_DIR/worktrees/<名前>/HEAD で見る。
# git 2.54 以降では、ジョブが自動メンテナンスを切っていないと、fetch の後の worktree prune --expire が prune_safe より先にこれらを外す。
held() { [ -e "$T/repo/.git/worktrees/$1/HEAD" ]; }
git_prunes() { LC_ALL=C git -C "$T/repo" worktree prune --dry-run -v 2>&1 | grep -qF "Removing worktrees/$1: "; }
detached_unique() { # detached_unique <パス>: どの ref にも無いコミットを HEAD に持つ detached の worktree を作る
    git -C "$T/repo" worktree add -q --detach "$1" origin/main
    git -C "$1" commit -q --allow-empty -m unique
    u=$(git -C "$1" rev-parse HEAD)
}
setup repo-prune-gitdir-missing
detached_unique "$T/det"
rm "$T/repo/.git/worktrees/det/gitdir"
check "git の prune が外す (前提)" git_prunes det
run_gc
check "登録が残る" held det
check "見送りと SHA がログに出る" logged "keep  $T/repo (prune 見送り: worktrees/det の detached HEAD $u がどの ref にも無い)"
check "通知が 1 本" notified_once "prune"

setup repo-prune-gitdir-empty
detached_unique "$T/det"
mv "$T/det" "$T/det.moved"
: >"$T/repo/.git/worktrees/det/gitdir"
check "git の prune が外す (前提)" git_prunes det
run_gc
check "登録が残る" held det
check "見送りと SHA がログに出る" logged "keep  $T/repo (prune 見送り: worktrees/det の detached HEAD $u がどの ref にも無い)"

# git は同じパスの登録のうち、worktrees/<名前> の名前順で最初のものを残し、残りを外す。外れる側にだけ固有のコミットを置く。
setup repo-prune-duplicate
git -C "$T/repo" worktree add -q --detach "$T/dup" origin/main
cp -R "$T/repo/.git/worktrees/dup" "$T/repo/.git/worktrees/dup2"
u=$(git -C "$T/repo" commit-tree -p origin/main -m unique "origin/main^{tree}")
echo "$u" >"$T/repo/.git/worktrees/dup2/HEAD"
check "git の prune が重複の側を外す (前提)" git_prunes dup2
run_gc
check "重複の登録が残る" held dup2
check "見送りと SHA がログに出る" logged "keep  $T/repo (prune 見送り: $T/dup の detached HEAD $u がどの ref にも無い)"

# フォルダだけ退けた登録も、index が 3 か月より古いと、ジョブの fetch の後の自動メンテナンスが外しうる (git 2.54 以降)。
setup repo-prune-detached-unique-old
gone_detached_unique "$T/det"
touch -t 202001010000 "$T/repo/.git/worktrees/det/index"
run_gc
check "登録が残る" registered "$T/det"
check "見送りと SHA がログに出る" logged "keep  $T/repo (prune 見送り: $T/det の detached HEAD $u がどの ref にも無い)"

# ---- $REPO の prune: dry-run が失敗した回・読めない行が在った回は、何が外れるか分からないので prune しない ----
fake_dry_run() { # fake_dry_run <fail|odd>: git worktree prune --dry-run だけを失敗させる / 読めない行を足す偽の git を前に差し込む
    mkdir -p "$T/bin"
    printf '#!/usr/bin/env bash
case " $* " in
  *" prune --dry-run "*) [ %q != fail ] || exit 1; %q "$@"; rc=$?; echo "Entferne worktrees/x: y" >&2; exit "$rc" ;;
esac
exec %q "$@"
' "$1" "$(command -v git)" "$(command -v git)" >"$T/bin/git"
    chmod +x "$T/bin/git"
}
setup repo-prune-dry-run-fails
git -C "$T/repo" worktree add -q --detach "$T/det" origin/main
mv "$T/det" "$T/det.moved"
fake_dry_run fail
run_gc PATH="$T/bin:$base/bin:$PATH"
check "登録が残る" registered "$T/det"
check "理由がログに出る" logged "keep  $T/repo (prune 見送り: git worktree prune --dry-run が失敗)"
check "通知は出さない" test ! -e "$T/notify-calls"

setup repo-prune-dry-run-unreadable
git -C "$T/repo" worktree add -q --detach "$T/det" origin/main
mv "$T/det" "$T/det.moved"
fake_dry_run odd
run_gc PATH="$T/bin:$base/bin:$PATH"
check "登録が残る" registered "$T/det"
check "読めない行がログに出る" logged "keep  $T/repo (prune 見送り: 読めない行か HEAD: Entferne worktrees/x: y)"
check "通知が 1 本" notified_once "prune"

# ---- $REPO の prune: reftable のリポでは worktrees/<名前>/HEAD のファイルが置き石なので、git が解決した HEAD で見る ----
setup repo-prune-reftable
if git clone -q --ref-format=reftable "$T/origin.git" "$T/rt" 2>/dev/null; then
    git -C "$T/rt" worktree add -q --detach "$T/det" origin/main
    git -C "$T/det" commit -q --allow-empty -m unique
    u=$(git -C "$T/det" rev-parse HEAD)
    mv "$T/det" "$T/det.moved"
    check "HEAD のファイルは置き石 (前提)" grep -qx 'ref: refs/heads/.invalid' "$T/rt/.git/worktrees/det/HEAD"
    run_gc REPO="$T/rt"
    check "登録が残る" test -e "$T/rt/.git/worktrees/det/HEAD"
    check "見送りと SHA がログに出る" logged "keep  $T/rt (prune 見送り: $T/det の detached HEAD $u がどの ref にも無い)"
else
    echo "skip [$CASE] git が reftable に対応していない"
fi

# ---- idle_shell: 放置されたシェルだけが居る Orca の worktree は、PR が閉じて MIN_AGE_HOURS たてば使用中に数えない ----
# 放置されたシェルは、偽の lsof (pid 900 の cwd が worktree)・偽の ps (900 の親は 1、端末 ttys123、子なし)・偽の stat (端末の時刻) で作る。
# 残すケースは、消すケース (idle-shell-on-removes) と同じ入力から 1 つだけ変える。削除の直前の取り直しも同じ判定で残すので、
# 判定の段の keep の行まで見る (rm が呼ばれないことだけだと、判定の柵を外しても取り直しが残して通ってしまう)。
H=3600
ago() { jq -nr --argjson s "$(($(date +%s) - $1))" '$s | todate'; } # ago <秒>: その秒数前の ISO 8601 (GNU と BSD の date の違いを避ける)
idle_shell() { # idle_shell <worktree> <端末の atime の秒前> [<mtime の秒前>]: 起きてから 1 週間たった回に、放置されたシェルを 1 本置く
    local now
    now=$(date +%s)
    printf 'p900\nfcwd\nn%s\n' "$1" >"$T/lsof-cwd"
    printf '  900     1 ttys123  -/bin/zsh\n  800     1 ??       /usr/sbin/daemon\n' >"$T/ps-out"
    printf '/dev/ttys123 %s %s\n' "$((now - $2))" "$((now - ${3:-$2}))" >"$T/stat-times"
    printf '{ sec = %s, usec = 0 } Mon Nov  9 00:00:00 2026\n' "$((now - 7 * 24 * H))" >"$T/sysctl-out"
}
idle_case() { # idle_case <ケース名> [<$T からのパス>]: 端末が 30h 前の放置されたシェルだけが居て、PR が 30h 前に閉じた Orca の worktree を WT に
    setup "$1"
    WT=$T/${2:-orca/wt}
    orca_wt "$WT" feat-o "$(ago $((30 * H)))" "$((($(date +%s) - 72 * H) * 1000))"
    idle_shell "$WT" $((30 * H))
}
idle_kept() { # idle_kept <判定の段の keep の行の理由 (先頭から)>
    check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
    check "残る" exists "$WT"
    check "理由がログに出る" logged "keep  $WT ($1"
}
IN_USE="cwd がこの中にあるプロセスが居る)"
RULE_COL="idle_shell: シェル 1 本 (端末 30h 無操作) を使用中に数えない / feat-o: PR #1 が MERGED"
ps_line() { sed -i.bak "s#^  900 .*#$1#" "$T/ps-out"; } # ps_line <行>: pid 900 の行を差し替える

idle_case idle-shell-off
run_gc
idle_kept "$IN_USE"
check "ps を呼ばない" test ! -e "$T/ps-calls"
check "stat を呼ばない" test ! -e "$T/stat-calls"
check "sysctl を呼ばない" test ! -e "$T/sysctl-calls"

idle_case idle-shell-on-removes
run_gc RULE_idle_shell=on
check "orca rm が呼ばれる" grep -qxF "$WT" "$T/rm-calls"
check "STALE に規則が出る" logged "STALE $WT ($RULE_COL"
check "台帳の worktree の行" col_has "$WT" 2 worktree
check "規則の列の先頭に idle_shell" col_starts "$WT" 4 "$RULE_COL"

idle_case idle-shell-list-plans
sha=$(git -C "$WT" rev-parse HEAD)
run_gc RULE_idle_shell=list
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "残る" exists "$WT"
check "PLAN の行" logged "PLAN  $WT ($RULE_COL)"
check "台帳は plan-worktree の 1 行だけ" test "$(awk -F'\t' '$2 == "plan-worktree"' "$LEDGER" 2>/dev/null | grep -c .)" = 1
check "台帳は 1 行 (worktree の行が無い)" rows 1
check "予定の規則" col_starts "$WT" 4 "$RULE_COL"
check "予定の戻し方" col_has "$WT" 5 "cd $T/repo && git worktree add -B feat-o $WT $sha"
check "鍵は規則・パス・HEAD" grep -qxF "idle_shell $WT $sha" "$T/state/cleanup-ledger/planned"
check "通知が出ない" test ! -e "$T/notify-calls"
run_gc RULE_idle_shell=list
check "もう 1 回流しても 1 行のまま" rows 1
check "2 回目も通知が出ない" test ! -e "$T/notify-calls"

idle_case idle-shell-path-with-space "orca/w t"
run_gc RULE_idle_shell=on
check "orca rm が呼ばれる" grep -qxF "$WT" "$T/rm-calls"

idle_case idle-shell-pr-closed-recently
jq --arg c "$(ago $((2 * H)))" '.[0].closedAt = $c' "$T/prs.json" >"$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
run_gc RULE_idle_shell=on
idle_kept "cwd がこの中にあるプロセスが居る"

idle_case idle-shell-tty-recent # 入力だけが在った (atime だけが新しい)
idle_shell "$WT" $((2 * H)) $((30 * H))
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-boundary-short # 実行に数秒かかるので、足りない側は 60 秒で作る
idle_shell "$WT" $((24 * H - 60))
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-boundary-exact
idle_shell "$WT" $((24 * H))
run_gc RULE_idle_shell=on
check "orca rm が呼ばれる" grep -qxF "$WT" "$T/rm-calls"

idle_case idle-shell-tty-future # 時計の巻き戻り
idle_shell "$WT" $((-H))
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-stat-fails
touch "$T/stat-fail"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-has-child
printf '  905   900 ttys123  sleep\n' >>"$T/ps-out"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-no-tty # /dev/?? の時刻も置く (stat の失敗で残るのと見分ける)
ps_line '  900     1 ??       -/bin/zsh'
printf '/dev/?? %s %s\n' $(($(date +%s) - 30 * H)) $(($(date +%s) - 30 * H)) >>"$T/stat-times"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-not-a-shell
ps_line '  900     1 ttys123  node'
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-not-a-shell-space
ps_line '  900     1 ttys123  /Applications/Some App/bin/tool'
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-mixed # 放置されたシェル 1 本と、サブディレクトリに居る別のプロセス (端末は同じく 30h 前。stat で残るのと見分ける)
printf 'p902\nfcwd\nn%s/sub\n' "$WT" >>"$T/lsof-cwd"
printf '  902     1 ttys124  node\n' >>"$T/ps-out"
printf '/dev/ttys124 %s %s\n' $(($(date +%s) - 30 * H)) $(($(date +%s) - 30 * H)) >>"$T/stat-times"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-after-wake # 起きてから 10 分
printf '{ sec = %s, usec = 0 } Tue Nov 17 00:00:00 2026\n' $(($(date +%s) - 600)) >"$T/sysctl-out"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-sysctl-fails
touch "$T/sysctl-fail"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-waketime-odd
echo 'kern.waketime: unknown' >"$T/sysctl-out"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

idle_case idle-shell-pid-missing-in-ps # 放置されたシェル 1 本と、ps に居ない pid
printf 'p903\nfcwd\nn%s\n' "$WT" >>"$T/lsof-cwd"
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

setup idle-shell-detached # PR を引けないので範囲外
WT=$T/orca/wt
git -C "$T/repo" worktree add -q --detach "$WT" origin/main
jq -n --arg p "$WT" '{result: {worktrees: [{path: $p, branch: null, isMainWorktree: false}]}}' >"$T/list.json"
ps_json "$WT" "$CREATED" done >"$T/ps.json"
idle_shell "$WT" $((30 * H))
run_gc RULE_idle_shell=on
idle_kept "$IN_USE"

setup idle-shell-repo-section # $REPO の節は PR を引かないので範囲外
WT=$T/repo-wt
merged_repo_wt "$WT" feat-a
idle_shell "$WT" $((30 * H))
run_gc RULE_idle_shell=on
check "残る" exists "$WT"
check "理由がログに出る" logged "keep  $WT ($IN_USE"

idle_case idle-shell-recheck # 判定の後、削除の直前 (2 回目の worktree ps) に、シェルでないプロセスが入ってくる
printf 'p902\nfcwd\nn%s\n' "$WT" >"$T/lsof-at-ps2"
printf '  902     1 ??       node\n' >>"$T/ps-out"
run_gc RULE_idle_shell=on
check "判定は通った (前提)" logged "STALE $WT ($RULE_COL"
check "orca rm が呼ばれない" test ! -e "$T/rm-calls"
check "理由がログに出る" logged "keep  $WT (削除直前に、cwd がこの中にあるプロセスを検出"

# ---- scratch_worktrees: セッションが scratchpad に作って残した、別のリポの worktree を、PR が閉じた後に消す ----
# 基準: 別のリポ (r2) の linked worktree が glob の下に在り、clean・cwd を持つプロセスなし・claude のプロセスなし・mtime は古い・
# 自分の PR が作成 (管理ディレクトリの作成時刻。偽の stat) の後、48h 前に閉じている。残すケースは基準から 1 つだけ変え、keep の行の理由まで見る。
# 偽の ps には claude でない行を 1 行置く (空の出力は「取れない」として残すので、claude が居ないことはこの形で作る)。
SID=0a1b2c3d-0000-4000-8000-000000000001
OTHER='"0a1b2c3d-0000-4000-8000-000000000002"'
OLD=202601010000
scratch_case() { # scratch_case <ケース名>: 基準の worktree を作り、パスを WT に
    setup "$1"
    git init -q --bare -b main "$T/o2.git"
    git clone -q "$T/o2.git" "$T/r2" 2>/dev/null
    git -C "$T/r2" commit -q --allow-empty -m init
    git -C "$T/r2" push -q origin main
    git -C "$T/r2" remote set-head origin main
    WT="$T/tmp/proj/$SID/scratchpad/wt/s1"
    mkdir -p "${WT%/*}"
    git -C "$T/r2" worktree add -q -b feat-s "$WT" origin/main
    echo s >"$WT/f.txt"
    git -C "$WT" add f.txt && git -C "$WT" commit -q -m "change feat-s"
    git -C "$WT" push -q -u origin feat-s 2>/dev/null
    git -C "$WT" push -q origin "HEAD:refs/pull/1/head" 2>/dev/null
    jq -n --arg c "$(ago $((48 * H)))" '[{number: 1, state: "MERGED", closedAt: $c}]' >"$T/prs.json"
    birth $((72 * H))
    printf '  800     1 ??       /usr/sbin/daemon\n' >"$T/ps-out"
    touch -t "$OLD" "$WT"
}
birth() { printf '%s %s\n' "$T/r2/.git/worktrees/s1" $(($(date +%s) - $1)) >"$T/stat-times"; } # birth <秒前>: 管理ディレクトリの作成時刻
scratch_gc() { run_gc RULE_scratch_worktrees=on "$@"; }
scratch_kept() { # scratch_kept <keep の行の理由 (先頭から)>
    check "残る" exists "$WT"
    check "理由がログに出る" logged "keep  $WT ($1"
}
claude_proc() { # claude_proc <pid> <comm> [<sessionId の JSON の値>]: 偽の ps に claude を 1 本足し、値があれば記録を置く
    printf '  %s     1 ttys001  %s\n' "$1" "$2" >>"$T/ps-out"
    [ $# -gt 2 ] || return 0
    mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
    printf '{"pid": %s, "sessionId": %s}\n' "$1" "$3" >"$CLAUDE_CONFIG_DIR/sessions/$1.json"
}
gh_call() { grep -F -- "--head $1 " "$T/gh-calls"; } # gh_call <ブランチ>: そのブランチの PR を引いた gh の呼び出し

scratch_case scratch-off
run_gc
check "残る" exists "$WT"
check "gh を呼ばない" test ! -e "$T/gh-calls"
check "ps を呼ばない" test ! -e "$T/ps-calls"
check "stat を呼ばない" test ! -e "$T/stat-calls"

scratch_case scratch-on-removes
sha=$(git -C "$WT" rev-parse HEAD)
scratch_gc
check "消える" gone "$WT"
check "登録も外れる" test -z "$(git -C "$T/r2" worktree list --porcelain | grep -F "$WT")"
check "台帳は 1 行" rows 1
check "種類は worktree" col_has "$WT" 2 worktree
check "規則の列の先頭に scratch_worktrees" col_starts "$WT" 4 "scratch_worktrees: feat-s: PR #1 が MERGED"
check "戻し方の cd の先は、その worktree のリポの本体" col_has "$WT" 5 "cd $T/r2 && git worktree add -B feat-s $WT $sha"
check "戻し方が貼って通る" restores_parse

scratch_case scratch-list-plans
sha=$(git -C "$WT" rev-parse HEAD)
run_gc RULE_scratch_worktrees=list
check "残る" exists "$WT"
check "PLAN の行" logged "PLAN  $WT (scratch_worktrees: feat-s: PR #1 が MERGED)"
check "台帳は plan-worktree の 1 行だけ" test "$(awk -F'\t' '$2 == "plan-worktree"' "$LEDGER" 2>/dev/null | grep -c .)" = 1
check "台帳は 1 行" rows 1
check "鍵は規則・パス・HEAD" grep -qxF "scratch_worktrees $WT $sha" "$T/state/cleanup-ledger/planned"
check "予定の戻し方の cd の先も、その worktree のリポの本体" col_has "$WT" 5 "cd $T/r2 && git worktree add -B feat-s $WT $sha"
check "通知が出ない" test ! -e "$T/notify-calls"
run_gc RULE_scratch_worktrees=list
check "もう 1 回流しても 1 行のまま" rows 1

scratch_case scratch-session-alive
claude_proc 700 claude "\"$SID\""
scratch_gc
scratch_kept "持ち主のセッション"

scratch_case scratch-session-alive-path # comm がパス付きで出ても claude に数える
claude_proc 700 /opt/claude/bin/claude "\"$SID\""
scratch_gc
scratch_kept "持ち主のセッション"

scratch_case scratch-session-other
claude_proc 700 claude "$OTHER"
scratch_gc
check "消える" gone "$WT"

for v in missing number; do # 記録を読めない claude が 1 本: ファイルが無い・sessionId が文字列でない
    scratch_case "scratch-claude-unreadable-$v"
    claude_proc 700 claude "$OTHER"
    if [ "$v" = missing ]; then claude_proc 701 claude; else claude_proc 701 claude 42; fi
    scratch_gc
    scratch_kept "持ち主のセッション"
    check "本数の行がログに出る" logged "claude 2 本のうち 1 本の記録を読めない。scratchpad の worktree は全部残す"
done

scratch_case scratch-ps-fails # ps-fail は偽の orca worktree ps も落とすので、答えのファイルを消して偽の ps だけを失敗させる
rm "$T/ps-out"
scratch_gc
scratch_kept "持ち主のセッション"

scratch_case scratch-ps-empty
: >"$T/ps-out"
scratch_gc
scratch_kept "持ち主のセッション"

scratch_case scratch-locked
git -C "$T/r2" worktree lock "$WT"
scratch_gc
scratch_kept "lock されている"

scratch_case scratch-dirty
touch "$WT/new.txt"
touch -t "$OLD" "$WT"
scratch_gc
scratch_kept "未コミットの変更あり"

scratch_case scratch-cwd
printf 'p900\nfcwd\nn%s/sub\n' "$WT" >"$T/lsof-cwd"
scratch_gc
scratch_kept "cwd がこの中にあるプロセスが居る"

scratch_case scratch-young
touch "$WT"
scratch_gc
scratch_kept "24h 以内に更新"

scratch_case scratch-no-pr
echo '[]' >"$T/prs.json"
scratch_gc
scratch_kept "feat-s: PR 無し"

scratch_case scratch-pr-open
echo '[{"number": 1, "state": "OPEN", "closedAt": null}]' >"$T/prs.json"
scratch_gc
scratch_kept "feat-s: PR 進行中"

scratch_case scratch-pr-closed-recently
jq --arg c "$(ago $((2 * H)))" '.[0].closedAt = $c' "$T/prs.json" >"$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
scratch_gc
scratch_kept "feat-s: PR #1 が MERGED だが、閉じてから 24h たっていない"

scratch_case scratch-pr-before-create # 48h 前に閉じた PR と、30h 前に作った管理ディレクトリ
birth $((30 * H))
scratch_gc
scratch_kept "feat-s: PR #1 が worktree の作成より前に閉じている"

scratch_case scratch-birth-stat-fails
touch "$T/stat-fail"
scratch_gc
scratch_kept "作成時刻を取れない"

scratch_case scratch-birth-zero # 作成時刻を持たないファイルシステムは 0 を返す
printf '%s 0\n' "$T/r2/.git/worktrees/s1" >"$T/stat-times"
scratch_gc
scratch_kept "作成時刻を取れない"

scratch_case scratch-own-prs-only
orca_wt "$T/orca/wt" feat-o "$AFTER" "$CREATED"
scratch_gc
check "scratch の呼び出しに --author @me" eval 'gh_call feat-s | grep -qF -- "--author @me"'
check "Orca の呼び出しは在る (前提)" eval 'gh_call feat-o >/dev/null'
check "Orca の呼び出しに --author が無い" eval '! gh_call feat-o | grep -qF -- "--author"'

scratch_case scratch-commits-outside-pr
echo x >"$WT/g.txt"
git -C "$WT" add g.txt && git -C "$WT" commit -q -m local
touch -t "$OLD" "$WT"
scratch_gc
scratch_kept "feat-s: PR #1 に無いコミットあり"

scratch_case scratch-ignored-unknown
printf '%s\n' .env node_modules/ >>"$T/r2/.git/info/exclude"
mkdir -p "$WT/node_modules/x"
touch "$WT/.env" "$WT/node_modules/x/a"
touch -t "$OLD" "$WT"
scratch_gc IGNORED_OK=node_modules
scratch_kept "無視されるファイル: .env"
check "IGNORED_OK の名前は理由に出さない" test -z "$(grep "keep  $WT (無視.*node_modules" "$T/log")"

scratch_case scratch-ignored-ok
echo node_modules/ >>"$T/r2/.git/info/exclude"
mkdir -p "$WT/node_modules/x"
touch "$WT/node_modules/x/a"
touch -t "$OLD" "$WT"
scratch_gc IGNORED_OK=node_modules
check "消える" gone "$WT"

scratch_case scratch-detached
git -C "$WT" switch -q --detach origin/main
touch -t "$OLD" "$WT"
birth $((48 * H))
scratch_gc
check "消える" gone "$WT"
check "規則" col_starts "$WT" 4 "scratch_worktrees: detached: origin/main に含まれる"

scratch_case scratch-detached-young
git -C "$WT" switch -q --detach origin/main
touch -t "$OLD" "$WT"
birth $((2 * H))
scratch_gc
scratch_kept "detached: 作成から 24h 以内"

scratch_case scratch-detached-commit # origin/HEAD に無いコミットを持つ
git -C "$WT" switch -q --detach
touch -t "$OLD" "$WT"
scratch_gc
scratch_kept "detached: デフォルトブランチに無いコミットを持つ"

scratch_case scratch-plain-dir # glob の下の、ただのフォルダ・clone・submodule は触らず、ログにも出さない
d=${WT%/*}
mkdir -p "$d/plain"
git clone -q "$T/o2.git" "$d/clone" 2>/dev/null
sup="$T/tmp/proj/0a1b2c3d-0000-4000-8000-000000000003/scratchpad/wt" # wt/ そのものを superproject にし、wt/sub を submodule に
git clone -q "$T/o2.git" "$sup" 2>/dev/null
git -C "$sup" -c protocol.file.allow=always submodule add -q "$T/o2.git" sub 2>/dev/null
touch -t "$OLD" "$d/plain" "$d/clone" "$sup/sub"
scratch_gc
check "submodule が出来た (前提)" test -f "$sup/sub/.git"
check "基準の worktree は消える (前提: 節は動いた)" gone "$WT"
check "フォルダ・clone・submodule は残る" eval 'exists "$d/plain" && exists "$d/clone" && exists "$sup/sub"'
check "ログに出さない" test -z "$(grep -F -e "$d/plain" -e "$d/clone" -e "$sup/sub" "$T/log")"

scratch_case scratch-keep-list
echo "$WT" >"$KEEPLIST"
scratch_gc
scratch_kept "「触らない」リスト"

scratch_case scratch-orca-pinned
ps_json "$WT" "$CREATED" done | jq '.result.worktrees[0].isPinned = true' >"$T/ps.json"
scratch_gc
scratch_kept "Orca でピン留め"

scratch_case scratch-orca-unreachable
touch "$T/orca-unreachable"
scratch_gc
scratch_kept "Orca に届かず"

scratch_case scratch-path-odd # glob を変えてパスに scratchpad が無ければ、持ち主が分からないので残す
mkdir -p "$T/elsewhere"
git -C "$T/r2" worktree move "$WT" "$T/elsewhere/s1"
WT=$T/elsewhere/s1
touch -t "$OLD" "$WT"
scratch_gc SCRATCH_WT_GLOB="$T/elsewhere/*"
scratch_kept "パスから持ち主のセッションを読めない"

# $REPO の worktree が glob の下に在れば、$REPO の節だけが判定する ($REPO の節が残すものを、scratch の節の条件で消さない)。
# REPO は symlink を通して渡す (パスの綴りで比べると、ここで二重に判定する)。
setup scratch-repo-wt-once
W="$T/tmp/proj/$SID/scratchpad/wt/r"
mkdir -p "${W%/*}"
merged_repo_wt "$W" feat-a
git -C "$W" push -q origin "HEAD:refs/pull/1/head" 2>/dev/null
jq -n --arg c "$(ago $((48 * H)))" '[{number: 1, state: "MERGED", closedAt: $c}]' >"$T/prs.json"
printf '%s %s\n' "$T/repo/.git/worktrees/r" $(($(date +%s) - 72 * H)) >"$T/stat-times"
printf '  800     1 ??       /usr/sbin/daemon\n' >"$T/ps-out"
ln -s "$T/repo" "$T/repo-link"
scratch_gc REPO="$T/repo-link"
check "消える" gone "$W"
check "scratch の節は gh を呼ばない" test ! -e "$T/gh-calls"
check "台帳は 1 行" rows 1
check "規則は \$REPO の節のもの" col_starts "$W" 4 "feat-a: upstream が remote から消滅"

# 別のリポの worktree で remove が拒否されたら、その本体の一覧で登録を確かめ、登録が残っていれば台帳に書かない
# ($REPO の一覧で見ると、登録が無いので「登録だけ外れた」と読み、偽の worktree-remove-failed を書く)。
scratch_case scratch-remove-fails
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\ncase " $* " in *" worktree remove "*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v git)" >"$T/bin/git"
chmod +x "$T/bin/git"
scratch_gc PATH="$T/bin:$base/bin:$PATH"
check "残る" exists "$WT"
check "WARN が出る" logged "WARN: remove 失敗 $WT"
check "台帳に行が無い" test ! -s "$LEDGER"

# 判定の後 (偽の gh が呼ばれた時点) に持ち主の記録と claude のプロセスが現れたら、compose を止めずに残す。
scratch_case scratch-recheck-session
printf '%s\t%s\n' wt-stack "$WT/docker" >"$T/docker-ps.tsv"
cat >"$T/at-gh" <<EOF
mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
printf '{"sessionId": "%s"}\n' "$SID" >"$CLAUDE_CONFIG_DIR/sessions/700.json"
printf '  700     1 ttys001  claude\n' >>"$T/ps-out"
EOF
scratch_gc
check "判定は通った (前提)" logged "STALE $WT (scratch_worktrees: "
scratch_kept "削除直前に、lock または持ち主のセッションを検出"
check "compose を止めない" not_called wt-stack

# 同じ時点で lock されたら、compose を止めずに残す。
scratch_case scratch-recheck-locked
printf '%s\t%s\n' wt-stack "$WT/docker" >"$T/docker-ps.tsv"
printf 'git -C %q worktree lock %q\n' "$T/r2" "$WT" >"$T/at-gh"
scratch_gc
check "判定は通った (前提)" logged "STALE $WT (scratch_worktrees: "
scratch_kept "削除直前に、lock または持ち主のセッションを検出"
check "compose を止めない" not_called wt-stack

for f in "$base"/*/log; do grep -q '^exit=0$' "$f" || { echo "FAIL [$(basename "$(dirname "$f")")] exit が 0 でない"; fail=1; }; done
[ "$fail" = 0 ] && echo "ok: worktree-gc"
exit "$fail"
