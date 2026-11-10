#!/usr/bin/env bash
#
# worktree と、それに紐づく docker compose プロジェクトを掃除する。
# 対象は $REPO の worktree と、Orca が管理する全リポの worktree ($ORCA_ROOT 配下)。
# launchd から毎時 0 分に実行される。定義は home/worktree-gc.nix。
#
# 手で確認するとき:
#   DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/worktree-gc.sh
#
set -euo pipefail

# launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin だけで、docker も nix の git も入らない。
# ここで通さないとジョブが黙って何もせず終わる。launchd 側 (worktree-gc.nix) でも同じ順で渡しているので、
# 上書きせず後ろに足す (tests/worktree-gc.sh が偽のコマンドを前に差し込めるように)。
PATH="$PATH:/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# どのリポを掃除するか (REPO・BASE・PROJECT_PREFIXES) は公開リポに置かず、手元の設定ファイルで渡す。
# 環境変数で渡した値はそちらが勝つ。REPO が無ければ何もしない。
CONFIG="${WORKTREE_GC_CONFIG:-$HOME/.config/worktree-gc.env}"
# 空文字も「渡した」とみなすので、値ではなく宣言ごと控えて読み込み後に戻す。
_env="$(declare -p REPO BASE PROJECT_PREFIXES 2>/dev/null || true)"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"
eval "$_env"
REPO="${REPO:-}"
# detached の worktree が固有のコミットを持たないかを見る基準のブランチ。
BASE="${BASE:-origin/main}"
# Orca が worktree を作る場所。ここ配下は Orca 経由で判定・削除し、$REPO の判定には混ぜない。
ORCA_ROOT="${ORCA_ROOT:-$HOME/orca/workspaces}"
# 削除の全条件に効かせる最終ガード。稼働中のエージェントが作った直後の worktree は
# 「detached・clean・$BASE と同一」で内容ベースの判定を全部すり抜けるため、
# 新しいものは一律で見送る (次の実行で拾える)。
MIN_AGE_HOURS="${MIN_AGE_HOURS:-24}"
# working_dir が消えた孤児の compose プロジェクトを落とす対象にする名前の接頭辞。共有インフラ (mysql,
# traefik...) や他リポジトリ、本体を巻き込まないための境界。空なら孤児は落とさない。
# このスクリプトが消した worktree に属するプロジェクトは、名前を問わず working_dir で拾う。
PROJECT_PREFIXES="${PROJECT_PREFIXES-}"
# build cache はここより古いものだけ捨てる。image は dangling のみ (-a を付けると
# ベースイメージが毎日消えて build のたびに再 pull になる)。
BUILDER_CACHE_MAX_AGE="${BUILDER_CACHE_MAX_AGE:-168h}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# 消してよいと判定された worktree を登録する。
# ただし ~/.herdr/worktrees/ 配下は herdr が自前で workspace 状態を持っており、
# `git worktree remove` を直接叩くとその状態と食い違う。herdr は Nix 管理外で
# 自己更新するため launchd から CLI を叩くのも壊れやすい。ここは候補として
# ログに出すだけに留め、削除はユーザーが herdr 経由で行う。
mark_stale() {
    local wt="$1" why="$2"
    case "$wt" in
        "$HOME/.herdr/worktrees/"*)
            log "keep  $wt ($why / herdr 管理下のため自動削除しない → herdr worktree remove --workspace <ID> --force)"
            return 0
            ;;
    esac
    log "STALE $wt ($why$(ignored_note "$wt"))"
    removable+=("$wt")
}

# .env などの ignore されたファイルは「未コミット変更なし」扱いで worktree ごと消える。
# 判定は変えず、消えるものがあることだけログに残す (ディレクトリは 1 件に数える)。
ignored_note() {
    local n
    n=$(git -C "$1" status --porcelain --ignored 2>/dev/null | grep -c '^!! ' || true)
    [ "$n" -gt 0 ] && printf ' / ignored %s 件も消える' "$n"
    return 0
}

# 実行するコマンドの出力はここで捨てる。呼び出し側に >/dev/null を書くと
# DRY-RUN のログまで一緒に消えて、何もしていないのに動いたように見える。
run() {
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: $*"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

# git status が失敗したとき (index.lock、壊れた worktree) も「変更あり」に倒す。
# 出力だけを見ると、失敗が clean に見えてそのまま削除候補になる。
is_dirty() {
    local out
    out=$(git -C "$1" status --porcelain 2>/dev/null) || return 0
    [ -n "$out" ]
}

# Orca の worktree ごとのエージェント状態。取れない・行数上限で打ち切られたときは失敗を返す。
# 失敗を '{}' で埋めると全 worktree が「エージェント無し」に見えて、作業中のものが消える。
orca_ps() {
    local out
    out=$(orca worktree ps --json 2>/dev/null) || return 1
    jq -e '.ok == true and .result.truncated == false' >/dev/null 2>&1 <<<"$out" || return 1
    printf '%s' "$out"
}

agents_busy() {
    jq -r --arg p "$1" '[.result.worktrees[]? | select(.path == $p) | .agents[]?.state | select(. != "done")] | join(",")' <<<"$2"
}

# worktree の中に working_dir を持つ compose プロジェクトを、消す前に止める。
# bind mount の中に named volume を重ねたマウント先 (storage/ など) は、コンテナが動いている間は
# Docker Desktop が掴んでいてホストから消せない。そのまま消すと Permission denied で途中で止まり、
# git の登録だけ外れたフォルダが残って Orca の削除も止まる。
# down ではなく stop にする: 削除が拒否されたとき、コンテナが残っていれば匿名ボリュームの参照も残り、
# 末尾の `docker volume prune` に消されない。止める前に動いていたコンテナの ID は running に入れる。
stop_stacks() {
    local wt="$1" proj dir id
    local seen=" "
    running=()
    docker info >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r proj dir; do
        [ -n "$proj" ] && [ -n "$dir" ] || continue
        case "$dir" in "$wt"|"$wt"/*) ;; *) continue ;; esac
        [[ "$seen" == *" $proj "* ]] && continue
        seen+="$proj "
        while read -r id; do [ -n "$id" ] && running+=("$id"); done \
            < <(docker ps -q --filter "label=com.docker.compose.project=$proj")
        log "stop  $proj — $wt を消す前に止める"
        run docker compose -p "$proj" stop || log "WARN: stop 失敗 $proj"
    done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' | sort -u)
    # コンテナが止まってもマウントが外れるまで 1 秒弱かかる (実測)。
    if [ "$seen" != " " ] && [ "$DRY_RUN" != "1" ]; then sleep 3; fi
    return 0
}

# 削除が拒否された worktree の環境は、止める前に動いていたコンテナだけ動かし直す
# (`compose start` はプロジェクト内で元から止まっていたサービスまで起こす)。
restart_stacks() {
    [ ${#running[@]} -gt 0 ] || return 0
    log "start ${running[*]} — worktree を消せなかったので戻す"
    run docker start "${running[@]}" >/dev/null || log "WARN: start 失敗 ${running[*]}"
}

[ -d "$REPO" ] || { log "repo が無い: $REPO"; exit 0; }

log "=== worktree-gc 開始 (repo=$REPO dry_run=$DRY_RUN) ==="

# ---- 取り残された index.lock を消す ----
# git は SIGKILL されると lock を消せない (timeout 付きで git を叩くツールや、落ちたエージェント)。
# 本体の lock が残ると Orca がローカル dev を fast-forward できず、worktree の lock が残ると
# その worktree で add/commit できなくなる。1 時間以上前のもので、かつ git が 1 本も
# 動いていないときだけ stale とみなす (エディタ待ちの commit などは git プロセスが居る)。
if pgrep -x git >/dev/null; then
    log "keep  index.lock の掃除は見送り (git が実行中)"
else
    while read -r lock; do
        log "stale-lock $lock"
        run rm -f "$lock"
    done < <(find "$REPO/.git" -maxdepth 3 -name index.lock -mmin +60 2>/dev/null)
fi

# upstream が消えたか (= PR が merge/close された) を見るために必要。
# オフライン時はこの判定だけ諦めて、孤児の掃除は続ける。
# upstream が fork 元 (origin 以外) を指すブランチもあるので、全 remote を取る。
fetch_ok=1
git -C "$REPO" fetch --prune --all --quiet 2>/dev/null || { fetch_ok=0; log "WARN: fetch 失敗。upstream-gone 判定はスキップする"; }

# ---- 削除してよい worktree を選ぶ ----
removable=()
# cwd が worktree の中にあるプロセス (シェル、エージェント、テスト) が居れば使用中とみなす。
# ルートの mtime はサブディレクトリの編集では変わらないので、それだけでは見逃す。
# lsof が使えないときは誰が使っているか分からないので、削除を全部見送る。
cwd_snapshot() {
    cwds_ok=1
    cwds=$(lsof -a -d cwd -Fn -u "$USER" 2>/dev/null | sed -n 's/^n//p') || cwds_ok=0
    [ -n "$cwds" ] || cwds_ok=0
}
cwd_snapshot
in_use() { awk -v p="$1" '$0 == p || index($0, p "/") == 1 { f = 1; exit } END { exit !f }' <<<"$cwds"; }

while read -r wt; do
    [ "$wt" = "$REPO" ] && continue
    # Orca の worktree は下の Orca の節で判定する。ここで `git worktree remove` すると Orca の状態とずれる。
    case "$wt" in "$ORCA_ROOT"/*) continue ;; esac

    if is_dirty "$wt"; then
        log "keep  $wt (未コミットの変更あり、または git status 失敗)"
        continue
    fi

    if [ "$cwds_ok" = "0" ]; then
        log "keep  $wt (lsof でプロセスの cwd を取れず、使用中か判定できない)"
        continue
    fi
    if in_use "$wt"; then
        log "keep  $wt (cwd がこの中にあるプロセスが居る)"
        continue
    fi

    if [ -z "$(find "$wt" -maxdepth 0 -mmin "+$((MIN_AGE_HOURS * 60))" 2>/dev/null)" ]; then
        log "keep  $wt (${MIN_AGE_HOURS}h 以内に更新: 使用中の可能性)"
        continue
    fi

    if branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null); then
        upstream=$(git -C "$wt" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null || true)
        if [ -z "$upstream" ]; then
            log "keep  $wt ($branch: upstream 無し = 未 push)"
        elif [ "$fetch_ok" = "0" ]; then
            log "keep  $wt ($branch: fetch 失敗のため判定不能)"
        elif git -C "$wt" show-ref --verify --quiet "refs/remotes/$upstream"; then
            log "keep  $wt ($branch: upstream 健在 = PR 進行中)"
        else
            mark_stale "$wt" "$branch: upstream が remote から消滅 = merge/close 済み"
        fi
    else
        # detached。$BASE から辿れる = 固有のコミットを持たない使い捨て。
        if git -C "$wt" merge-base --is-ancestor HEAD "$BASE" 2>/dev/null; then
            mark_stale "$wt" "detached: $BASE に含まれる"
        else
            log "keep  $wt (detached: $BASE に無いコミットを持つ)"
        fi
    fi
done < <(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2}')

# ---- Orca の worktree (全リポ) から削除してよいものを選ぶ ----
# 条件はグローバル CLAUDE.md「委任の線引き」と同じ: PR が MERGED / CLOSED、未コミット変更なし、
# PR に入っていないコミットなし、中のエージェントが作業中でない。PR の有無で判定し、
# PR が worktree の作成より前に閉じていれば同名ブランチの別作業とみなす (MIN_AGE_HOURS は使わない)。
# 削除は orca worktree rm に任せる。マージ済みと証明できないブランチは Orca が残す。
orca_removable=()

# PR に入っていないローカルコミットがあれば 0 を返す。squash merge で ancestry が切れるので、
# デフォルトブランチにも PR の head にも無いコミットを、patch-id で PR のコミットと照合する
# (push 前に rebase した旧版は差分が同じなので一致する。件名だと amend 後の未 push 版や
# "fix tests" のような汎用件名を取り違える)。判定できないときは「ある」に倒す。
has_commits_outside_pr() {
    local wt="$1" num="$2" base head mb ids c id
    base=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 0
    git -C "$wt" fetch --quiet origin "pull/$num/head" 2>/dev/null || return 0
    head=$(git -C "$wt" rev-parse --verify --quiet FETCH_HEAD) || return 0
    mb=$(git -C "$wt" merge-base "$head" "$base" 2>/dev/null) || return 0
    ids=$(git -C "$wt" log -p --no-merges "$mb..$head" | git -C "$wt" patch-id --stable | cut -d' ' -f1) || return 0
    while read -r c; do
        [ -n "$c" ] || continue
        id=$(git -C "$wt" show "$c" | git -C "$wt" patch-id --stable | cut -d' ' -f1) || return 0
        # 空コミットは patch-id が出ないので照合できない。
        [ -n "$id" ] && grep -qxF -- "$id" <<<"$ids" || return 0
    done < <(git -C "$wt" rev-list --no-merges HEAD --not "$base" "$head")
    return 1
}

if ! orca status --json 2>/dev/null | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1; then
    log "WARN: Orca のランタイムに届かない。Orca の worktree の掃除はスキップ (次回に拾う)"
elif ! ps_json=$(orca_ps); then
    log "WARN: orca worktree ps が取れない、または打ち切られた。エージェントの状態が分からないので Orca の worktree の掃除はスキップ"
else
    fetched=""
    while IFS=$'\t' read -r wt branch; do
        [ -d "$wt" ] || continue
        if is_dirty "$wt"; then
            log "keep  $wt (未コミットの変更あり、または git status 失敗)"
            continue
        fi
        # エージェントの状態だけでは使用中か分からない。ターンを終えて次の指示を待つセッションは done になり、
        # PR をマージした直後に同じ worktree で次の作業に入ることがある。$REPO の節と同じく、プロセスの cwd でも見る。
        if [ "$cwds_ok" = "0" ]; then
            log "keep  $wt (lsof でプロセスの cwd を取れず、使用中か判定できない)"
            continue
        fi
        if in_use "$wt"; then
            log "keep  $wt (cwd がこの中にあるプロセスが居る)"
            continue
        fi
        busy=$(agents_busy "$wt" "$ps_json")
        if [ -n "$busy" ]; then
            log "keep  $wt (エージェントが $busy)"
            continue
        fi

        # PR の head とデフォルトブランチを比べるので、リポごとに 1 回 fetch する。
        common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || continue
        case "$fetched" in
            *"|$common|"*) ;;
            *)
                git -C "$wt" fetch --quiet --prune --all 2>/dev/null || log "WARN: fetch 失敗 $common"
                # clone 以外で作ったリポには origin/HEAD が無く、デフォルトブランチとの比較が全部「判定不能」になる。
                git -C "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1 \
                    || git -C "$wt" remote set-head origin --auto >/dev/null 2>&1 \
                    || log "WARN: origin/HEAD を設定できない $common"
                fetched="$fetched|$common|"
                ;;
        esac
        def=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
        created=$(jq -r --arg p "$wt" '.result.worktrees[]? | select(.path == $p) | .createdAt // empty' <<<"$ps_json")

        # detached はブランチが無く PR を引けない。$REPO の detached と同じく、固有のコミットを持たない
        # 使い捨てだけを消す。作った直後のエージェントの worktree も同じ形なので、MIN_AGE_HOURS で見送る。
        if [ -z "$branch" ]; then
            if [ -z "$created" ] || [ "$created" -gt $((($(date +%s) - MIN_AGE_HOURS * 3600) * 1000)) ]; then
                log "keep  $wt (detached: 作成から ${MIN_AGE_HOURS}h 以内、または作成日時が取れない)"
            elif [ -n "$def" ] && git -C "$wt" merge-base --is-ancestor HEAD "$def" 2>/dev/null; then
                log "STALE $wt (detached: $def に含まれる$(ignored_note "$wt"))"
                orca_removable+=("$wt")
            else
                log "keep  $wt (detached: デフォルトブランチに無いコミットを持つ、または判定不能)"
            fi
            continue
        fi
        if [ "$branch" = "${def#origin/}" ]; then
            log "keep  $wt ($branch: デフォルトブランチ)"
            continue
        fi

        slug=$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
        if ! prs=$(gh pr list -R "$slug" --head "$branch" --state all --json number,state,closedAt 2>/dev/null); then
            log "keep  $wt ($branch: gh で PR を引けない)"
            continue
        fi
        if [ "$(jq 'length' <<<"$prs")" = "0" ]; then
            log "keep  $wt ($branch: PR 無し)"
            continue
        fi
        if jq -e 'any(.[]; .state == "OPEN")' <<<"$prs" >/dev/null; then
            log "keep  $wt ($branch: PR 進行中)"
            continue
        fi
        num=$(jq -r 'max_by(.number) | .number' <<<"$prs")
        # 閉じた PR と同名のブランチで作り直した worktree (決まった名前のブランチ、`--pr` で切り直したもの) は、
        # 作業前だと clean・固有コミット無しで旧 PR の判定を通ってしまう。作成より後に閉じた PR だけを根拠にする。
        closed=$(jq -r 'max_by(.number) | .closedAt // empty | fromdateiso8601 * 1000 | floor' <<<"$prs")
        if [ -z "$created" ] || [ -z "$closed" ] || [ "$closed" -lt "$created" ]; then
            log "keep  $wt ($branch: PR #$num が worktree の作成より前に閉じている、または日時が取れない)"
            continue
        fi
        if has_commits_outside_pr "$wt" "$num"; then
            log "keep  $wt ($branch: PR #$num に無いコミットあり)"
            continue
        fi
        log "STALE $wt ($branch: PR #$num が $(jq -r 'max_by(.number) | .state' <<<"$prs")$(ignored_note "$wt"))"
        orca_removable+=("$wt")
    done < <(orca worktree list --json 2>/dev/null | jq -r --arg root "$ORCA_ROOT" '
        .result.worktrees[]?
        | select((.isMainWorktree | not) and (.path | startswith($root + "/")))
        | [.path, ((.branch // "") | sub("^refs/heads/"; ""))] | @tsv')
fi

# ---- worktree を消す。ブランチは残るのでコミットは失われない ----
# 消せたものだけを removed に入れ、compose を落とす対象はここから決める。
# 候補の段階で落とすと、削除が拒否された worktree の環境だけが毎時壊れる。
removed=()
for wt in ${removable[@]+"${removable[@]}"}; do
    stop_stacks "$wt"
    if run git -C "$REPO" worktree remove "$wt" 2>/dev/null; then
        log "removed $wt"
        removed+=("$wt")
    else
        log "WARN: remove 失敗 $wt"
        restart_stacks
    fi
done
run git -C "$REPO" worktree prune

# ---- Orca の worktree を消す ----
# 判定から削除までに fetch や gh で数分空くので、直前に状態を取り直す。
if [ ${#orca_removable[@]} -gt 0 ] && ! ps_now=$(orca_ps); then
    log "WARN: 削除直前の orca worktree ps が取れない。Orca の worktree の削除は見送る (次回に拾う)"
    orca_removable=()
fi
for wt in ${orca_removable[@]+"${orca_removable[@]}"}; do
    if is_dirty "$wt"; then
        log "keep  $wt (削除直前に未コミットの変更を検出)"
        continue
    fi
    busy=$(agents_busy "$wt" "$ps_now")
    if [ -n "$busy" ]; then
        log "keep  $wt (削除直前にエージェントが $busy)"
        continue
    fi
    # 1 つ消すのに 1 分かかることがあるので、worktree ごとに取り直す。
    cwd_snapshot
    if [ "$cwds_ok" = "0" ] || in_use "$wt"; then
        log "keep  $wt (削除直前に、cwd がこの中にあるプロセスを検出、または lsof で取れない)"
        continue
    fi
    stop_stacks "$wt"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: orca worktree rm --worktree path:$wt"
        removed+=("$wt")
        continue
    fi
    if orca worktree rm --worktree "path:$wt" --json 2>/dev/null | jq -e '.ok == true' >/dev/null; then
        removed+=("$wt")
        # 削除はバックグラウンドで続くことがある。1 分待っても残るフォルダはログに出す。
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
            [ -d "$wt" ] || break
            sleep 5
        done
        if [ -d "$wt" ]; then log "WARN: orca rm 後もフォルダが残っている $wt"; else log "removed $wt"; fi
    else
        log "WARN: orca rm 失敗 $wt"
        restart_stacks
    fi
done

# ---- 消した worktree と孤児の compose プロジェクトを落とす ----
if docker info >/dev/null 2>&1; then
    docker ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' \
        | sort -u | while IFS=$'\t' read -r proj dir; do
        [ -n "$proj" ] && [ -n "$dir" ] || continue

        # 消した worktree のプロジェクトは名前を問わず、名前付きボリュームごと落とす
        # (`docker volume prune` は匿名ボリュームしか消さず、worktree ごとに積み上がる)。
        reason=""
        for wt in ${removed[@]+"${removed[@]}"}; do
            case "$dir" in "$wt"|"$wt"/*) reason="削除した worktree $wt に属する" ;; esac
        done
        if [ -n "$reason" ]; then
            log "down  $proj — $reason (ボリュームも削除)"
            run docker compose -p "$proj" down --remove-orphans --volumes || log "WARN: down 失敗 $proj"
            continue
        fi

        # 孤児はどの worktree のものか確かめようがないので、名前か場所で app の worktree と分かるものだけ。
        # ボリュームは残す (手で移動したディレクトリのデータを消さないため)。
        [ ! -d "$dir" ] || continue
        matched=0
        for prefix in $PROJECT_PREFIXES; do
            case "$proj" in "$prefix"*) matched=1 ;; esac
        done
        # Orca の worktree の compose 名は app-<worktree 名>-<hash> で接頭辞に当たらないので、working_dir で拾う。
        case "$dir" in "$ORCA_ROOT"/*) matched=1 ;; esac
        [ "$matched" = "1" ] || continue

        log "down  $proj — working_dir が既に無い (孤児)"
        run docker compose -p "$proj" down --remove-orphans || log "WARN: down 失敗 $proj"
    done
else
    log "WARN: docker が動いていない。コンテナの掃除はスキップ (次回、孤児として拾う)"
fi

# ---- ディスク回収 ----
if docker info >/dev/null 2>&1; then
    run docker image prune -f || true
    run docker volume prune -f || true
    run docker builder prune -f --filter "until=$BUILDER_CACHE_MAX_AGE" || true
    [ "$DRY_RUN" = "1" ] || log "prune 済み: dangling image / volume, build cache ($BUILDER_CACHE_MAX_AGE 超)"
    docker system df | sed 's/^/  /'
fi

log "=== 完了 (削除した worktree: ${#removed[@]}) ==="
