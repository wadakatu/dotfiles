#!/usr/bin/env bash
# home/scripts/worktree-gc.sh の「消してよいか」の判定を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/worktree-gc.sh
# git と lsof は本物、orca / gh / docker は偽物。作業中の worktree を消さないことを主に見る。
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
    # volume ls は docker-volumes (project<空白>volume) から引く。prune は何もしない。
    # volume-ls-fail があれば ls は失敗する。
    volume) [ "$2" != ls ] || { [ ! -f "$FAKE/volume-ls-fail" ] || exit 1; p=${5#label=com.docker.compose.project=}; awk -v p="$p" '$1 == p {print $2}' "$FAKE/docker-volumes" 2>/dev/null; } ;;
    system) [ ! -f "$FAKE/df-fail" ] || exit 1 ;;
esac
exit 0
EOF
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE/prs.json"
EOF
# worktree ps は呼ばれるたびに ps.<回数>.json を返す (無ければ ps.json)。ps-fail があれば失敗する。
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "status --json") echo '{"result": {"runtime": {"reachable": true}}}' ;;
    "worktree ps")
        [ -f "$FAKE/ps-fail" ] && exit 1
        n=$(($(cat "$FAKE/ps-count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE/ps-count"
        # spawn-at-ps2 があれば、2 回目 (削除の直前) に、そこに書かれたパスを cwd にしたプロセスを起こす。
        if [ "$n" = 2 ] && [ -f "$FAKE/spawn-at-ps2" ]; then
            (cd "$(cat "$FAKE/spawn-at-ps2")" && exec sleep 60) >/dev/null 2>&1 &
            echo $! >"$FAKE/spawned.pid"
            sleep 1
        fi
        if [ -f "$FAKE/ps.$n.json" ]; then cat "$FAKE/ps.$n.json"; else cat "$FAKE/ps.json"; fi ;;
    "worktree list") cat "$FAKE/list.json" ;;
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
chmod +x "$base/bin/"*

# 毎回作り直す: origin (bare) と、それを clone した本体 $T/repo。
setup() {
    CASE=$1
    T="$base/$CASE"
    # 台帳と会話記録の置き場所。run_gc を通らない呼び出しもあるので、関数の引数でなく export で全部に継がせる。
    export STATE_ROOT="$T/state" CLAUDE_CONFIG_DIR="$T/claude"
    LEDGER="$T/state/cleanup-ledger/ledger.tsv"
    mkdir -p "$T/orca"
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

for f in "$base"/*/log; do grep -q '^exit=0$' "$f" || { echo "FAIL [$(basename "$(dirname "$f")")] exit が 0 でない"; fail=1; }; done
[ "$fail" = 0 ] && echo "ok: worktree-gc"
exit "$fail"
