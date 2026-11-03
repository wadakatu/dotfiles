#!/usr/bin/env bash
# home/scripts/worktree-gc.sh の「消してよいか」の判定を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/worktree-gc.sh
# git と lsof は本物、orca / gh / docker は偽物。作業中の worktree を消さないことを主に見る。
set -u
# shellcheck disable=SC2016  # '...' の中の $x は偽コマンドの変数

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/worktree-gc.sh"
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
    ps) cat "$FAKE/docker-ps.tsv" ;;
    compose) echo "$*" >>"$FAKE/docker-calls" ;;
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
        if [ -f "$FAKE/ps.$n.json" ]; then cat "$FAKE/ps.$n.json"; else cat "$FAKE/ps.json"; fi ;;
    "worktree list") cat "$FAKE/list.json" ;;
    "worktree rm")
        wt=${4#path:}; echo "$wt" >>"$FAKE/rm-calls"
        git -C "$FAKE/repo" worktree remove --force "$wt" && echo '{"ok": true}' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$base/bin/"*

# 毎回作り直す: origin (bare) と、それを clone した本体 $T/repo。
setup() {
    CASE=$1
    T="$base/$CASE"
    mkdir -p "$T/orca"
    git init -q --bare -b main "$T/origin.git"
    git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
    git -C "$T/repo" commit -q --allow-empty -m init
    git -C "$T/repo" push -q origin main
    git -C "$T/repo" remote set-head origin main
    echo '[]' >"$T/prs.json"
}
run_gc() {
    env PATH="$base/bin:$PATH" FAKE="$T" REPO="$T/repo" ORCA_ROOT="$T/orca" WORKTREE_GC_CONFIG=/nonexistent PROJECT_PREFIXES="proj-" \
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

for f in "$base"/*/log; do grep -q '^exit=0$' "$f" || { echo "FAIL [$(basename "$(dirname "$f")")] exit が 0 でない"; fail=1; }; done
[ "$fail" = 0 ] && echo "ok: worktree-gc"
exit "$fail"
