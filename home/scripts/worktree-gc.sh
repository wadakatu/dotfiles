#!/usr/bin/env bash
#
# worktree と、それに紐づく docker compose プロジェクトを掃除する。
# 対象は $REPO の worktree と、Orca が管理する全リポの worktree ($ORCA_ROOT 配下)。
# $FF_CHECKOUTS の checkout は、origin のデフォルトブランチへ fast-forward だけで追従させる。
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

# fetch や merge の後に git が起こす自動メンテナンスは、git 2.54 では worktree prune --expire 3.months.ago を含み、
# prune_safe が確かめる前に登録を外す。このジョブの git (子プロセスも) では起こさない。
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false

# どのリポを掃除するか (REPO・BASE・PROJECT_PREFIXES・FF_CHECKOUTS) は公開リポに置かず、手元の設定ファイルで渡す。
# 環境変数で渡した値はそちらが勝つ。REPO が無ければ掃除はしない (FF_CHECKOUTS の追従だけ動く)。
CONFIG="${WORKTREE_GC_CONFIG:-$HOME/.config/worktree-gc.env}"
# 空文字も「渡した」とみなすので、値ではなく宣言ごと控えて読み込み後に戻す。
_env="$(declare -p REPO BASE PROJECT_PREFIXES FF_CHECKOUTS DRY_RUN 2>/dev/null || true)"
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
# checkout のまま使う道具など、誰も pull しないリポの絶対パス (空白区切り)。空なら何もしない。
# ponytail: 空白区切りなので空白を含むパスは扱えない。要るなら設定ファイルで配列にする。
FF_CHECKOUTS="${FF_CHECKOUTS-}"
# 規則 scratch_worktrees が探す、セッションの scratchpad の下の worktree。
# ponytail: 空白で割ってから glob を展開するので、パターンに空白を含められない (既定のパスには無い)。要るようになったら配列にする。
SCRATCH_WT_GLOB="${SCRATCH_WT_GLOB:-/private/tmp/claude-$(id -u)/*/*/scratchpad/wt/*}"
# 規則 scratch_worktrees で、一緒に消えてよい無視されるファイルの、先頭のパス要素の名前 (空白区切り。例: node_modules)。
IGNORED_OK="${IGNORED_OK-}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# 止めた・消したものの台帳と「触らない」リスト。launchd は origin/main の写しを動かすので、隣のこのファイルも同じ版になる。
# shellcheck source=home/scripts/cleanup-ledger.sh
. "$(dirname "${BASH_SOURCE[0]}")/cleanup-ledger.sh"

notify() {
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "worktree-gc"' -e 'end run' "$*" >/dev/null 2>&1 || true
}

# 毎時のことなので、同じ知らせはその日 1 回だけ出す。手で流す DRY_RUN では出さない (その日の本番の通知を消さないため)。
notify_daily() { # notify_daily <通知済みの印のファイル> <文言>
    [ "$DRY_RUN" != "1" ] && [ "$(cat "$1" 2>/dev/null)" != "$(date +%F)" ] || return 0
    notify "$2"
    { mkdir -p "${1%/*}" && date +%F >"$1"; } 2>/dev/null || log "WARN: 通知済みの印を書けない $1"
}

# 台帳に 1 行足し、最後の通知に出す種類を控える。DRY_RUN では何も消えていないので書かない (ここ 1 か所で弾く)。
# 台帳に書けなくても掃除は続ける。削除と down の間で止まると、volume だけが残る。
recorded=()
record() {
    [ "$DRY_RUN" = "1" ] && return 0
    ledger_add "$@" || log "WARN: 台帳に書けない $CLEANUP_LEDGER"
    recorded+=("$1")
}

# そこに居た Claude Code のセッションのうち、最後に書かれたものの ID と、セッションの数を 1 行で出す。会話記録は
# ~/.claude/projects/<パスの英数字以外を - にした名前>/<ID>.jsonl で、変換した名前が 200 字を超えると 200 字に
# 切り詰めて hash が付く (https://code.claude.com/docs/en/sessions.md の "Where transcripts are stored")。
# hash の作りは公開されていないので、先頭 200 字で始まるディレクトリが 1 つだけのときに使う (2 つ以上なら取り違えうるので空)。
# ponytail: 英数字以外を 1 バイトずつ置き換えるので、日本語などを含むパスは Claude Code の名前と合わず空になる。
sessions_of() {
    local root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" name d f new="" n=0
    name=$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')
    if [ ${#name} -le 200 ]; then
        d="$root/$name"
    else
        d=$(find "$root" -mindepth 1 -maxdepth 1 -type d -name "${name:0:200}*" 2>/dev/null || true)
        [ "$(grep -c . <<<"$d")" = 1 ] || return 0
    fi
    [ -d "$d" ] || return 0
    for f in "$d"/*.jsonl; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        if [ -z "$new" ] || [ "$f" -nt "$new" ]; then new=$f; fi
    done
    if [ -n "$new" ]; then new=${new##*/}; printf '%s %s\n' "${new%.jsonl}" "$n"; fi
    return 0
}

# 消す前に、戻すのに要るもの (本体・ブランチ・HEAD・そこに居たセッション) と、戻らないもの (無視されるファイル) を
# wt_restore と wt_lost に控える。消した後では引けない。stop_stacks の前に呼ぶ (ここで落ちて、止めたコンテナが戻らないのを避ける)。
wt_snapshot() {
    local wt="$1" main branch sha id ig n
    wt_restore="" wt_lost=""
    main=$(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || true)
    sha=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)
    # 戻し方の列は、そのまま端末に貼って通るコマンドだけにする。注記は先頭の `: <注記>; ` に置く
    # (: は引数を読み捨てるだけ。# は対話の zsh では既定でコメントにならない)。注記にはシェルの特殊文字を入れない。
    # SHA が空のまま git worktree add を書くと、貼ったときに本体の HEAD から黙って作るので、戻し方を書かない。
    if [ -z "$sha" ]; then
        wt_restore=": HEAD を取れなかったので戻し方なし"
    else
        # git -C ではなく cd にするのは、台帳の戻し方を `git worktree add` の形のまま grep で引けるようにするため。
        if branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null); then
            wt_restore="cd $(printf %q "$main") && git worktree add -B $(printf %q "$branch") $(printf %q "$wt") $sha"
        else
            wt_restore="cd $(printf %q "$main") && git worktree add --detach $(printf %q "$wt") $sha"
        fi
        read -r id n <<<"$(sessions_of "$wt" || true)" || true
        if [ -n "$id" ]; then
            wt_restore="$wt_restore && cd $(printf %q "$wt") && claude --resume $(printf %q "$id")"
            if [ "$n" -gt 1 ]; then wt_restore=": ほか $((n - 1)) 件は claude --resume の一覧から; $wt_restore"; fi
        fi
    fi
    # ディレクトリは 1 件に数える (ignored_note と同じ)。
    ig=$(git -C "$wt" status --porcelain --ignored 2>/dev/null | sed -n 's/^!! //p' || true)
    n=$(grep -c . <<<"$ig" || true)
    if [ "$n" -gt 0 ]; then
        wt_lost="無視されるファイル $n 件: $(awk 'NR <= 20 { printf "%s%s", (NR > 1 ? ", " : ""), $0 }' <<<"$ig")"
        if [ "$n" -gt 20 ]; then wt_lost="$wt_lost ほか $((n - 20)) 件"; fi
    fi
    return 0
}

# 消せた worktree を台帳に書く。消す前の compose の stop は書かない: 直後の down --volumes でコンテナごと消えるので、
# 戻し方 (docker start) が打てない。<戻らないもの> は節ごとの追記 (Orca のカードなど)。
record_removed() { # record_removed <worktree> <当たった規則> [<戻らないもの>]
    local lost="$wt_lost"
    if [ -n "${3:-}" ]; then lost="${lost:+$lost / }$3"; fi
    if [ -n "$stack_vols" ]; then lost="${lost:+$lost / }compose の volume ($stack_vols) は down --volumes で消える"; fi
    record worktree "$1" "$2" "$wt_restore" "$lost"
}

# git worktree remove が失敗しても、中身を消す途中で失敗した回は登録だけ外れ、.git の残ったフォルダになる
# (実測: ignore された書けないディレクトリがあると Permission denied で止まり、登録は外れる)。そうなると残った
# フォルダからはブランチも SHA も引けないので 0 を返す。登録が残っていれば (lock など) 何も変わっていない。
wt_broken() { # wt_broken <worktree> <本体>
    local list
    [ -e "$1/.git" ] || return 0
    # 一覧を取れない回は登録が外れたか分からないので、壊れていないとみなす (分からないことを台帳に書かない)。
    # パイプの grep -q は git を SIGPIPE で落とし、pipefail で「登録が無い」に化けうるので、出力を受けてから探す。
    list=$(git -C "$2" worktree list --porcelain 2>/dev/null) || return 1
    ! grep -qxF -- "worktree $1" <<<"$list"
}

# down --volumes で消える volume の名前を ", " 区切りで出す。down の後では引けないので、その前に呼ぶ。
# 引けなかった回は、volume が無い回 (空) と区別できるよう「名前を引けなかった」と出す (注記ごと落とさない)。
stack_volumes() {
    local out
    out=$(docker volume ls -q --filter "label=com.docker.compose.project=$1" 2>/dev/null) || { printf '名前を引けなかった'; return 0; }
    awk 'NF { printf "%s%s", (n++ ? ", " : ""), $0 }' <<<"$out"
}

# 消してよいと判定された worktree を登録する。
# ただし ~/.herdr/worktrees/ 配下は herdr が自前で workspace 状態を持っており、
# `git worktree remove` を直接叩くとその状態と食い違う。herdr は Nix 管理外で
# 自己更新するため launchd から CLI を叩くのも壊れやすい。ここは候補として
# ログに出すだけに留め、削除はユーザーが herdr 経由で行う。
mark_stale() { # mark_stale <worktree> <理由> [<本体> (既定は $REPO)]
    local wt="$1" why="$2"
    case "$wt" in
        "$HOME/.herdr/worktrees/"*)
            log "keep  $wt ($why / herdr 管理下のため自動削除しない → herdr worktree remove --workspace <ID> --force)"
            return 0
            ;;
    esac
    log "STALE $wt ($why$(ignored_note "$wt"))"
    # 規則は台帳に書くので、同じ添字で並べて持つ (bash 3.2 には連想配列が無い)。
    removable+=("$wt")
    removable_why+=("$why")
    removable_main+=("${3:-$REPO}")
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

# Orca でピン留めした worktree は「触らない」リストと同じく残す。true 以外 (欠けている・null) はピン留めでない。
pinned() {
    jq -e --arg p "$1" 'any(.result.worktrees[]?; .path == $p and .isPinned == true)' >/dev/null 2>&1 <<<"$2"
}

# 「触らない」リストに当たる compose project なら、理由をログに出して 0 を返す。名前か working_dir のどちらかで当てる。
kept_stack() {
    keep_match "$1" "$2" || return 1
    log "keep  $1 (「触らない」リスト)"
}

# worktree の中に working_dir を持つ compose プロジェクトを、消す前に止める。
# bind mount の中に named volume を重ねたマウント先 (storage/ など) は、コンテナが動いている間は
# Docker Desktop が掴んでいてホストから消せない。そのまま消すと Permission denied で途中で止まり、
# git の登録だけ外れたフォルダが残って Orca の削除も止まる。
# down ではなく stop にする: 削除が拒否されたとき、コンテナが残っていれば匿名ボリュームの参照も残り、
# 末尾の `docker volume prune` に消されない。止める前に動いていたコンテナの ID は running に入れる。
# この worktree のプロジェクト名は stacks (改行区切り。名前に空白があっても割れない) に、台帳に書く volume の名前は
# stack_vols に入れる。
# 「触らない」リストに当たるプロジェクトが中に居れば、1 つも止めずに 1 を返す。呼び側は worktree ごと残す
# (止めずに消すと上の理由で削除が途中で止まり、止めれば守ったことにならない)。
stop_stacks() {
    local wt="$1" proj dir id v
    running=() stacks="" stack_vols=""
    if ! docker info >/dev/null 2>&1; then
        # 名前の行は compose project にしか当たらない。Docker に届かないと、守る project が中に居るか分からないので、
        # 名前の行が 1 つでもあれば worktree を残す (消すと project の working_dir が消える)。
        case "$keep_entries" in
            n:* | *$'\n'n:*)
                log "keep  $wt (Docker に届かず、「触らない」リストの名前の行に当たる compose が中に居るか分からない)"
                return 1
                ;;
        esac
        return 0
    fi
    while IFS=$'\t' read -r proj dir; do
        [ -n "$proj" ] && [ -n "$dir" ] || continue
        case "$dir" in "$wt"|"$wt"/*) ;; *) continue ;; esac
        if keep_match "$proj" "$dir"; then
            log "keep  $wt (compose $proj が「触らない」リスト)"
            return 1
        fi
        case $'\n'"$stacks" in *$'\n'"$proj"$'\n'*) continue ;; esac
        stacks+="$proj"$'\n'
    done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' | sort -u)
    # 1 行ずつ読む (for で回すと、手で付けた label の空白で名前が割れ、別の名前を止める)。中の docker が
    # 名前の一覧を標準入力から読み食いしないよう、fd 3 で渡す。
    while IFS= read -r proj <&3; do
        [ -n "$proj" ] || continue
        v=$(stack_volumes "$proj")
        if [ -n "$v" ]; then stack_vols="${stack_vols:+$stack_vols / }$proj: $v"; fi
        while read -r id; do [ -n "$id" ] && running+=("$id"); done \
            < <(docker ps -q --filter "label=com.docker.compose.project=$proj")
        log "stop  $proj — $wt を消す前に止める"
        run docker compose -p "$proj" stop || log "WARN: stop 失敗 $proj"
    done 3<<<"$stacks"
    # コンテナが止まってもマウントが外れるまで 1 秒弱かかる (実測)。
    if [ -n "$stacks" ] && [ "$DRY_RUN" != "1" ]; then sleep 3; fi
    return 0
}

# 削除が拒否された worktree の環境は、止める前に動いていたコンテナだけ動かし直す
# (`compose start` はプロジェクト内で元から止まっていたサービスまで起こす)。
# start も失敗すると止めたままになり、ほかに知らせる所が無いので、その回だけ台帳に compose-stop を書く。
# 削除は拒否されたのでコンテナは残っており、docker start で戻せる。
restart_stacks() { # restart_stacks <worktree>
    local id cmd="docker start" names
    [ ${#running[@]} -gt 0 ] || return 0
    log "start ${running[*]} — worktree を消せなかったので戻す"
    run docker start "${running[@]}" && return 0
    log "WARN: start 失敗 ${running[*]}"
    for id in "${running[@]}"; do cmd="$cmd $(printf %q "$id")"; done
    names=${stacks%$'\n'}
    record compose-stop "${names//$'\n'/ }" "$1 を消す前に止めたが、削除が拒否され、docker start も失敗" "$cmd" ""
}

# $FF_CHECKOUTS を origin のデフォルトブランチへ fast-forward する。人が使っている途中かもしれないので、
# ブランチの切り替え・stash・依存の入れ直しはしない。条件に合わなければ何も変えず、理由を 1 行出して次へ。
ff_checkouts() {
    local dir f op def cur old new now
    for dir in $FF_CHECKOUTS; do
        op="" def="" cur="" old="" new="" now=""
        if [ ! -d "$dir/.git" ]; then
            log "ff-skip $dir (.git がディレクトリでない: linked worktree か、存在しない)"
            continue
        fi
        for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply sequencer; do
            if [ -e "$dir/.git/$f" ]; then op=$f; break; fi
        done
        if [ -n "$op" ]; then
            log "ff-skip $dir (git の操作の途中: $op)"
            continue
        fi
        if ! git -C "$dir" fetch --quiet origin 2>/dev/null; then
            log "ff-skip $dir (fetch 失敗)"
            continue
        fi
        if ! def=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
            log "ff-skip $dir (origin/HEAD が無く、追従先が分からない)"
            continue
        fi
        cur=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        if [ "$cur" != "${def#origin/}" ]; then
            log "ff-skip $dir (${cur:-detached} はデフォルトブランチ ${def#origin/} でない)"
            continue
        fi
        if is_dirty "$dir"; then
            log "ff-skip $dir (未コミットの変更あり、または git status 失敗)"
            continue
        fi
        old=$(git -C "$dir" rev-parse --verify --quiet HEAD 2>/dev/null || true)
        new=$(git -C "$dir" rev-parse --verify --quiet "$def" 2>/dev/null || true)
        [ "$old" = "$new" ] && continue
        if ! git -C "$dir" merge-base --is-ancestor HEAD "$def" 2>/dev/null; then
            log "ff-skip $dir ($def に無いローカルコミットがある、または分岐している)"
            continue
        fi
        if ! run git -C "$dir" merge --ff-only --quiet "$def"; then
            log "WARN: ff 失敗 $dir"
            continue
        fi
        [ "$DRY_RUN" = "1" ] && continue
        # 確認から merge までの間に人がブランチを切り替えたら、切り替え先が進んだかもしれない。
        now=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        if [ "$now" = "$cur" ]; then
            log "ff    $dir ${old:0:7}..${new:0:7}"
        else
            log "WARN: $dir のブランチが確認の後で ${now:-detached} に変わった。${now:-HEAD} が $def に fast-forward されたかもしれない (git -C $dir reflog ${now:-HEAD})"
        fi
    done
    return 0
}
ff_checkouts

[ -d "$REPO" ] || { log "repo が無い: $REPO"; exit 0; }

log "=== worktree-gc 開始 (repo=$REPO dry_run=$DRY_RUN) ==="

# 「触らない」リストが無い・読めない回 (解釈できない行がある回を含む) は、何を守るべきか分からないので、ここから先 (index.lock の掃除、
# worktree の削除、compose の stop / down、prune) を全部見送る。FF_CHECKOUTS の追従は何も消さないので上で済ませている。
# 通知はその日 1 回だけ (notify_daily)。「無い」と「読めない行が在る」は印を分ける (同じ日に、無い → 作った → 書き間違い、でも 2 本目が出るように)。
if ! keep_load; then
    if [ "$keep_error" = bad ]; then
        log "WARN: 「触らない」リスト $CLEANUP_KEEP に読めない行がある。この回は何も止めず何も消さない"
        warned="$STATE_ROOT/worktree-gc/keep-unreadable-warned"
        msg="「触らない」リスト $CLEANUP_KEEP に読めない行があるので掃除を止めています (行番号はログに)"
    else
        log "WARN: 「触らない」リスト $CLEANUP_KEEP が無いか読めない。この回は何も止めず何も消さない (守るものが無ければ空のファイルを置く)"
        warned="$STATE_ROOT/worktree-gc/keep-missing-warned"
        msg="「触らない」リスト $CLEANUP_KEEP が無いので掃除を止めています。守るものが無ければ空のファイルを置く"
    fi
    notify_daily "$warned" "$msg"
    exit 0
fi

# ---- 取り残された index.lock を消す ----
# git は SIGKILL されると lock を消せない (timeout 付きで git を叩くツールや、落ちたエージェント)。
# 本体の lock が残ると Orca がローカル dev を fast-forward できず、worktree の lock が残ると
# その worktree で add/commit できなくなる。1 時間以上前のもので、かつ git が 1 本も
# 動いていないときだけ stale とみなす (エディタ待ちの commit などは git プロセスが居る)。
# 「触らない」リストに当たる worktree の lock は消さない (守ると決めたものは、中の git の状態も触らない)。
# worktree の lock は .git/worktrees/<名前>/ に在り、その worktree のパスは隣の gitdir (<パス>/.git) に書いてある。
# git worktree add --relative-paths (git 2.48 から) の gitdir は .git/worktrees/<名前>/ からの相対パスなので、
# 絶対パスに直してから比べる。直せなければ守るものか分からないので 1 を返し、呼び側は lock を残す。
lock_owner() {
    local d=${1%/index.lock} g
    if [ "$d" = "$REPO/.git" ]; then printf '%s' "$REPO"; return 0; fi
    g=$(cat "$d/gitdir" 2>/dev/null) || return 0
    g=${g%/.git}
    case $g in /*) ;; *) g=$(cd "$d/$g" 2>/dev/null && pwd) || return 1 ;; esac
    printf '%s' "$g"
}
if pgrep -x git >/dev/null; then
    log "keep  index.lock の掃除は見送り (git が実行中)"
else
    while read -r lock; do
        if ! owner=$(lock_owner "$lock"); then
            log "keep  index.lock $lock (gitdir の相対パスを解けず、持ち主の worktree が分からない)"
            continue
        fi
        if keep_match "$owner"; then
            log "keep  index.lock $lock (「触らない」リスト)"
            continue
        fi
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
removable=() removable_why=() removable_main=()
# 時刻は整数だけを比べる。[ -lt ] は整数でないと終了 2 で偽になり、「消してよい」側へ素通りする。
is_uint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; }
# cwd が worktree の中にあるプロセス (シェル、エージェント、テスト) が居れば使用中とみなす。
# ルートの mtime はサブディレクトリの編集では変わらないので、それだけでは見逃す。
# lsof が使えないときは誰が使っているか分からないので、削除を全部見送る。
# lsof の出力は p<pid> と n<パス> の行が組で出る。規則 idle_shell が off でなければ、同じ時点のプロセスの一覧も取る。
idle_mode=$(rule_mode idle_shell)
cwd_snapshot() {
    cwds_ok=1
    cwd_raw=$(lsof -a -d cwd -Fpn -u "$USER" 2>/dev/null) || cwds_ok=0
    cwds=$(sed -n 's/^n//p' <<<"$cwd_raw")
    [ -n "$cwds" ] || cwds_ok=0
    idle_ok=0
    [ "$idle_mode" = off ] || idle_snapshot
}
in_use() { awk -v p="$1" '$0 == p || index($0, p "/") == 1 { f = 1; exit } END { exit !f }' <<<"$cwds"; }

# 規則 idle_shell の材料を取る。使える回だけ idle_ok=1 にし、プロセスの一覧 (pid ppid tty コマンド名) を procs に置く。
# 長く眠った直後は全部の端末が古く見えるので、起きてから 1 時間たつまでは使わない。起きた時刻が読めない・数字でない・
# 今より先の回も使わない。出力は `{ sec = <秒>, usec = <マイクロ秒> } <日付>` の形 (agent-resume.sh の kern.boottime と同じ)。
# 失敗は全部「使わない」で受けて 0 を返す (トップレベルから呼ぶので、1 を返すと set -e がジョブごと落とす)。
idle_snapshot() {
    local wake now
    procs=""
    wake=$(sysctl -n kern.waketime 2>/dev/null | sed -nE 's/^\{ sec = ([0-9]+),.*/\1/p') || return 0
    now=$(date +%s) || return 0
    # 今より先の時刻は差が負になり、ここで落ちる。
    is_uint "$wake" && [ $((now - wake)) -ge 3600 ] || return 0
    procs=$(ps -axo pid=,ppid=,tty=,comm= 2>/dev/null) || return 0
    if [ -n "$procs" ]; then idle_ok=1; fi
    return 0
}

# <worktree> の中に cwd を持つプロセスが全部「放置されたシェル」なら 0 を返し、本数を idle_n に、端末が最後に動いてからの
# 時間 (いちばん新しい端末で、時間単位) を idle_h に置く。放置されたシェルは、コマンド名 (先頭の - とディレクトリを落とす。
# ログインシェルは -/bin/zsh の形) が zsh・bash・sh・fish で、それを親とするプロセスが無く、端末を持ち、端末の atime と mtime の
# 新しい方 (出力だけが在った端末も動いているとみなす) が MIN_AGE_HOURS 以上前のもの。1 つでも欠ける・取れない・形が想定外
# (ps に居ない pid、stat の失敗、数字でない時刻、今より先の時刻) なら 1 (使用中)。if の中で呼ぶので set -e は効かない。
idle_only() {
    local pid row p ppid tty name t a m now kids newest=0
    idle_n=0 idle_h=""
    [ "$idle_ok" = 1 ] || return 1
    now=$(date +%s) || return 1
    while IFS= read -r pid; do
        is_uint "$pid" || return 1
        row=$(awk -v p="$pid" '$1 == p { print; exit }' <<<"$procs") || return 1
        [ -n "$row" ] || return 1
        # コマンド名は空白を含みうるので、4 列目から行末までを取る。
        read -r p ppid tty name <<<"$row"
        name=${name#-}
        case "${name##*/}" in zsh | bash | sh | fish) ;; *) return 1 ;; esac
        # 端末の無いプロセスの ?? も、英数字と / 以外を含むのでここで落ちる。
        case "$tty" in '' | *[!A-Za-z0-9/]*) return 1 ;; esac
        kids=$(awk -v p="$pid" '$2 == p { n++ } END { print n + 0 }' <<<"$procs") || return 1
        [ "$kids" = 0 ] || return 1
        t=$(stat -f '%a %m' "/dev/$tty" 2>/dev/null) || return 1
        read -r a m <<<"$t"
        is_uint "$a" && is_uint "$m" || return 1
        if [ "$a" -gt "$m" ]; then m=$a; fi
        # 今より先の時刻 (時計の巻き戻り) は差が負になり、ここで落ちる。
        [ $((now - m)) -ge $((MIN_AGE_HOURS * 3600)) ] || return 1
        if [ "$m" -gt "$newest" ]; then newest=$m; fi
        idle_n=$((idle_n + 1))
    done < <(awk -v p="$1" '/^p/ { pid = substr($0, 2) }
        /^n/ { x = substr($0, 2); if ((x == p || index(x, p "/") == 1) && !seen[pid]++) print pid }' <<<"$cwd_raw")
    [ "$idle_n" -gt 0 ] || return 1
    idle_h=$(((now - newest) / 3600))
}
cwd_snapshot

# Orca でピン留めした worktree は、$REPO の節でも Orca の節でも残す。Orca の一覧は $ORCA_ROOT の外の worktree も
# 持つので、両方の節の前で 1 回だけ取る。orca コマンドが無い環境では、ピン留めは無いものとして進む。
# Orca に届かない・ps が取れない回は、ピン留めもエージェントの状態も分からないので、両方の節の削除を見送る
# (全部ピン留めとみなすのと同じ)。
ps_json=""
if ! command -v orca >/dev/null 2>&1; then
    orca_state=absent
    log "orca コマンドが無い。Orca の worktree の掃除は飛ばし、ピン留めは無いものとして進む"
elif ! orca status --json 2>/dev/null | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1; then
    orca_state=unknown
    log "WARN: Orca のランタイムに届かない。ピン留めが分からないので、Orca と $REPO の worktree の掃除はスキップ (次回に拾う)"
elif ! ps_json=$(orca_ps); then
    orca_state=unknown
    log "WARN: orca worktree ps が取れない、または打ち切られた。エージェントの状態とピン留めが分からないので、Orca と $REPO の worktree の掃除はスキップ"
else
    orca_state=ok
fi

while read -r wt; do
    [ "$wt" = "$REPO" ] && continue
    # Orca の worktree は下の Orca の節で判定する。ここで `git worktree remove` すると Orca の状態とずれる。
    case "$wt" in "$ORCA_ROOT"/*) continue ;; esac

    if keep_match "$wt"; then
        log "keep  $wt (「触らない」リスト)"
        continue
    fi
    if [ "$orca_state" = unknown ]; then
        log "keep  $wt (Orca に届かず、ピン留めが分からない)"
        continue
    fi
    if [ "$orca_state" = ok ] && pinned "$wt" "$ps_json"; then
        log "keep  $wt (Orca でピン留め)"
        continue
    fi
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
orca_removable=() orca_why=()

# PR に入っていないローカルコミットがあれば 0 を返す。squash merge で ancestry が切れるので、
# デフォルトブランチにも PR の head にも無いコミットを、patch-id で PR のコミットと照合する
# (push 前に rebase した旧版は差分が同じなので一致する。件名だと amend 後の未 push 版や
# "fix tests" のような汎用件名を取り違える)。判定できないときは「ある」に倒す。
# PR の head は FETCH_HEAD でなく、その worktree だけの ref (refs/worktree/ の下は worktree ごとで共有されない) に取る。
# 本体やほかの worktree の ref を増やさず、worktree を消せば一緒に消える。fetch が失敗した回は、前の回の ref を読まない。
# 行き先のある refspec は、PR の head を指す tag を共有の refs/tags に連れてくるので、--no-tags で止める (実測)。
has_commits_outside_pr() {
    local wt="$1" num="$2" base head mb ids c id
    base=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || return 0
    git -C "$wt" fetch --quiet --no-write-fetch-head --no-tags origin "+pull/$num/head:refs/worktree/gc/pr-head" 2>/dev/null || return 0
    head=$(git -C "$wt" rev-parse --verify --quiet refs/worktree/gc/pr-head) || return 0
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

# ブランチの PR で、その worktree を消してよいかを決める。消してよければ 0 を返し、理由を pr_why に、PR が閉じた時刻 (ms) を
# pr_closed に置く。残すときは理由を keep の行に出して 1 を返す。
# 呼び側の if や || の中では set -e が効かないので、取れなかった値は全部「残す」に落とす (空の slug で gh を呼ばない)。
# 時刻は is_uint で整数と確かめてから比べる。own を渡すと自分の PR だけを引く (gh pr list --author @me)。
pr_stale() { # pr_stale <worktree> <ブランチ> <worktree の作成時刻 (ms)> [own]
    local wt="$1" branch="$2" created="$3" slug prs num closed
    pr_why="" pr_closed=""
    slug=$(git -C "$wt" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') || slug=""
    # gh が成功しても、出力が配列でなければ (空・JSON でない) PR を引けていない。
    # --author は配列で組まない (bash 3.2 の set -u では、空の配列の展開で落ちる)。
    # shellcheck disable=SC2086
    if [ -z "$slug" ] || ! prs=$(gh pr list -R "$slug" --head "$branch" ${4:+--author @me} --state all --json number,state,closedAt 2>/dev/null) \
        || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs"; then
        log "keep  $wt ($branch: gh で PR を引けない)"
        return 1
    fi
    if [ "$(jq 'length' <<<"$prs")" = "0" ]; then
        log "keep  $wt ($branch: PR 無し)"
        return 1
    fi
    if jq -e 'any(.[]; .state == "OPEN")' <<<"$prs" >/dev/null; then
        log "keep  $wt ($branch: PR 進行中)"
        return 1
    fi
    num=$(jq -r 'max_by(.number) | .number' <<<"$prs") || num=""
    # 閉じた PR と同名のブランチで作り直した worktree (決まった名前のブランチ、`--pr` で切り直したもの) は、
    # 作業前だと clean・固有コミット無しで旧 PR の判定を通ってしまう。作成より後に閉じた PR だけを根拠にする。
    closed=$(jq -r 'max_by(.number) | .closedAt // empty | fromdateiso8601 * 1000 | floor' <<<"$prs") || closed=""
    if ! is_uint "$created" || ! is_uint "$closed" || [ "$closed" -lt "$created" ]; then
        log "keep  $wt ($branch: PR #$num が worktree の作成より前に閉じている、または日時が取れない)"
        return 1
    fi
    if has_commits_outside_pr "$wt" "$num"; then
        log "keep  $wt ($branch: PR #$num に無いコミットあり)"
        return 1
    fi
    if ! pr_why="$branch: PR #$num が $(jq -r 'max_by(.number) | .state' <<<"$prs")"; then
        pr_why=""
        log "keep  $wt ($branch: PR #$num の状態を読めない)"
        return 1
    fi
    pr_closed=$closed
}

# Orca の状態は $REPO の節の前で取った (ps_json)。取れなかった回はこの節ごと見送る。
if [ "$orca_state" = ok ]; then
    fetched=""
    while IFS=$'\t' read -r wt branch; do
        [ -d "$wt" ] || continue
        if keep_match "$wt"; then
            log "keep  $wt (「触らない」リスト)"
            continue
        fi
        if pinned "$wt" "$ps_json"; then
            log "keep  $wt (Orca でピン留め)"
            continue
        fi
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
        # 規則 idle_shell (off 以外) では、中に居るのが放置されたシェルだけなら、PR が閉じてからの時間を見るまで持ち越す。
        # PR を引けない detached は対象外。
        idle_why=""
        if in_use "$wt"; then
            if [ "$idle_mode" = off ] || [ -z "$branch" ] || ! idle_only "$wt"; then
                log "keep  $wt (cwd がこの中にあるプロセスが居る)"
                continue
            fi
            idle_why="idle_shell: シェル $idle_n 本 (端末 ${idle_h}h 無操作) を使用中に数えない"
        fi
        busy=$(agents_busy "$wt" "$ps_json")
        if [ -n "$busy" ]; then
            log "keep  $wt (エージェントが $busy)"
            continue
        fi

        # PR の head とデフォルトブランチを比べるので、リポごとに 1 回 fetch する。FETCH_HEAD は worktree ごとに在り、
        # そこで作業する人のものなので書かない。
        common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || continue
        case "$fetched" in
            *"|$common|"*) ;;
            *)
                git -C "$wt" fetch --quiet --no-write-fetch-head --prune --all 2>/dev/null || log "WARN: fetch 失敗 $common"
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
                orca_why+=("detached: $def に含まれる")
            else
                log "keep  $wt (detached: デフォルトブランチに無いコミットを持つ、または判定不能)"
            fi
            continue
        fi
        if [ "$branch" = "${def#origin/}" ]; then
            log "keep  $wt ($branch: デフォルトブランチ)"
            continue
        fi

        pr_stale "$wt" "$branch" "$created" || continue
        if [ -n "$idle_why" ]; then
            # 端末の時刻だけでは、セッションを止めた翌日に PR をマージすると次の毎時に消える。閉じた時刻だけでは、プロンプトで
            # 手を止めている人の worktree が消える。両方を要る。pr_closed は pr_stale が整数と確かめた ms (比べられなければ残す)。
            if ! [ "$pr_closed" -le $((($(date +%s) - MIN_AGE_HOURS * 3600) * 1000)) ]; then
                log "keep  $wt (cwd がこの中にあるプロセスが居る / 放置されたシェルだけだが、PR が閉じてから ${MIN_AGE_HOURS}h たっていない)"
                continue
            fi
            pr_why="$idle_why / $pr_why"
            if [ "$idle_mode" = list ]; then
                wt_snapshot "$wt"
                ledger_plan "idle_shell $wt $(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)" \
                    worktree "$wt" "$pr_why" "$wt_restore" "$wt_lost" || log "WARN: 台帳に予定を書けない $CLEANUP_LEDGER"
                log "PLAN  $wt ($pr_why)"
                continue
            fi
        fi
        log "STALE $wt ($pr_why$(ignored_note "$wt"))"
        orca_removable+=("$wt")
        orca_why+=("$pr_why")
    done < <(orca worktree list --json 2>/dev/null | jq -r --arg root "$ORCA_ROOT" '
        .result.worktrees[]?
        | select((.isMainWorktree | not) and (.path | startswith($root + "/")))
        | [.path, ((.branch // "") | sub("^refs/heads/"; ""))] | @tsv')
fi

# ---- セッションが scratchpad に作って残した worktree (規則 scratch_worktrees) ----
# エージェントは別のリポへのコミットを <scratchpad>/wt/<名前> の worktree で行い、途中で止まったセッションの分が残る。
# どのリポのものでも、持ち主のセッションが居なくなり、自分の PR が閉じてから MIN_AGE_HOURS たったものを、その worktree の本体から消す。

# 動いている claude (ps のコマンド名から先頭の - とディレクトリを落として claude) の記録
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json から、文字列の sessionId を owners (改行区切り) に置く。
# 記録の形は公開されていないので、ps が失敗した・空だった回と、記録を読めない claude が 1 本でも居る回は 1 を返す
# (呼び側は全部「生きている」として残す)。if や || の中で呼ぶ。
scratch_owners() {
    local out pid sid n=0 m=0
    owners=""
    out=$(ps -axo pid=,ppid=,tty=,comm= 2>/dev/null) && [ -n "$out" ] || { log "WARN: ps でプロセスの一覧を取れない。scratchpad の worktree は全部残す"; return 1; }
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        n=$((n + 1))
        if sid=$(jq -er '.sessionId | strings | select(. != "")' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json" 2>/dev/null); then
            owners+="$sid"$'\n'
        else
            m=$((m + 1))
        fi
    done < <(awk 'match($0, /^ *[0-9]+ +[0-9]+ +[^ ]+ +/) {
        c = substr($0, RLENGTH + 1); sub(/^-/, "", c); sub(/.*\//, "", c); if (c == "claude") print $1 }' <<<"$out")
    [ "$m" = 0 ] && return 0
    log "claude $n 本のうち $m 本の記録を読めない。scratchpad の worktree は全部残す"
    return 1
}
# パスの scratchpad の 1 つ上の名前 (持ち主のセッション ID) を出す。パスに /scratchpad/ が無い、名前が英数字と - _ 以外を含むなら 1。
scratch_sid() {
    local p=${1%/scratchpad/*}
    [ "$p" != "$1" ] || return 1
    p=${p##*/}
    case "$p" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
    printf '%s' "$p"
}
# <本体> の一覧に <worktree> が在り、lock されていなければ 0。一覧を取れない・見つからないときは 1 (lock か分からない)。
wt_unlocked() { # wt_unlocked <本体> <worktree>
    local list
    list=$(git -C "$1" worktree list --porcelain 2>/dev/null) || return 1
    awk -v p="$2" '/^worktree / { cur = substr($0, 10) } cur == p { found = 1 } cur == p && /^locked( |$)/ { locked = 1 }
        END { exit !(found && !locked) }' <<<"$list"
}
# 無視されるファイルのうち、先頭のパス要素が IGNORED_OK に無いものを、先頭 3 件まで ", " 区切りで出す。git status の失敗は 1。
ignored_unknown() {
    local out
    out=$(git -C "$1" status --porcelain --ignored 2>/dev/null) || return 1
    awk -v ok="$IGNORED_OK" 'BEGIN { k = split(ok, a, /[ \t]+/); for (i = 1; i <= k; i++) if (a[i] != "") A[a[i]] = 1 }
        sub(/^!! /, "") { c = $0; sub(/\/.*/, "", c); if (!(c in A) && n++ < 3) printf "%s%s", (n > 1 ? ", " : ""), $0 }' <<<"$out"
}

scratch_mode=$(rule_mode scratch_worktrees)
# off では探しもしない (ps も gh も呼ばない)。$REPO の worktree は上の $REPO の節で判定したので、本体の .git で見分けて飛ばす
# ($REPO の節が残すと決めたもの (upstream が健在など) を、この節の別の条件で消さない。パスの綴りでなく .git で比べる)。
if [ "$scratch_mode" != off ] && ! repo_common=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    log "WARN: $REPO の .git を引けず、scratchpad の worktree と見分けられない。scratchpad の worktree は全部残す"
elif [ "$scratch_mode" != off ]; then
    owners_ok=1
    scratch_owners || owners_ok=0
    # shellcheck disable=SC2086 # パターンを glob として展開する
    for wt in $SCRATCH_WT_GLOB; do
        [ -d "$wt" ] || continue
        # glob が symlink を通っても (/tmp など)、git の --show-toplevel は物理パスを返すので、物理パスに直してから見分ける。
        # 後ろの判定 (「触らない」リスト、ピン留め、lock、cwd、台帳、削除) も全部このパスで行う。直せなければ飛ばす。
        wt=$(cd "$wt" 2>/dev/null && pwd -P) || continue
        # linked worktree だけを見る。ただのフォルダ・clone・submodule はここで外れ、ログにも出さない。
        gd=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || continue
        common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
        top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || continue
        [ "$gd" != "$common" ] && [ "$top" = "$wt" ] || continue
        [ "$common" != "$repo_common" ] || continue
        main=$(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') || main=""
        if [ -z "$main" ]; then
            log "keep  $wt (scratchpad: 本体を引けない)"
            continue
        fi
        if keep_match "$wt"; then
            log "keep  $wt (「触らない」リスト)"
            continue
        fi
        if [ "$orca_state" = unknown ]; then
            log "keep  $wt (Orca に届かず、ピン留めが分からない)"
            continue
        fi
        if [ "$orca_state" = ok ] && pinned "$wt" "$ps_json"; then
            log "keep  $wt (Orca でピン留め)"
            continue
        fi
        # lock と持ち主は gh より前に見る (削除の直前にも取り直す)。
        if ! wt_unlocked "$main" "$wt"; then
            log "keep  $wt (lock されている、または $main の git worktree list に見つからない)"
            continue
        fi
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
        if ! sid=$(scratch_sid "$wt"); then
            log "keep  $wt (パスから持ち主のセッションを読めない)"
            continue
        fi
        if [ "$owners_ok" = 0 ] || grep -qxF -- "$sid" <<<"$owners"; then
            log "keep  $wt (持ち主のセッション $sid が動いている、または分からない)"
            continue
        fi
        if [ -z "$(find "$wt" -maxdepth 0 -mmin "+$((MIN_AGE_HOURS * 60))" 2>/dev/null)" ]; then
            log "keep  $wt (${MIN_AGE_HOURS}h 以内に更新: 使用中の可能性)"
            continue
        fi
        if ! ig=$(ignored_unknown "$wt"); then
            log "keep  $wt (git status --ignored 失敗)"
            continue
        fi
        if [ -n "$ig" ]; then
            log "keep  $wt (無視されるファイル: $ig が IGNORED_OK に無い)"
            continue
        fi
        # 作成時刻は管理ディレクトリ (<共通の .git>/worktrees/<名前>) の作成時刻 (秒)。作成時刻を持たないファイルシステムは 0 を返す。
        created=$(stat -f %B "$gd" 2>/dev/null) || created=""
        if ! is_uint "$created" || [ "$created" -le 0 ]; then
            log "keep  $wt (作成時刻を取れない)"
            continue
        fi
        def=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
        if branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null); then
            if [ "$branch" = "${def#origin/}" ]; then
                log "keep  $wt ($branch: デフォルトブランチ)"
                continue
            fi
            pr_stale "$wt" "$branch" "$((created * 1000))" own || continue
            if ! [ "$pr_closed" -le $((($(date +%s) - MIN_AGE_HOURS * 3600) * 1000)) ]; then
                log "keep  $wt ($pr_why だが、閉じてから ${MIN_AGE_HOURS}h たっていない)"
                continue
            fi
            why="scratch_worktrees: $pr_why"
        else
            # detached は PR を引けない。Orca の detached と同じく、作成から時間がたち、固有のコミットを持たないものだけ。
            if [ "$created" -gt $(($(date +%s) - MIN_AGE_HOURS * 3600)) ]; then
                log "keep  $wt (detached: 作成から ${MIN_AGE_HOURS}h 以内)"
                continue
            fi
            if [ -z "$def" ] || ! git -C "$wt" merge-base --is-ancestor HEAD "$def" 2>/dev/null; then
                log "keep  $wt (detached: デフォルトブランチに無いコミットを持つ、または判定不能)"
                continue
            fi
            why="scratch_worktrees: detached: $def に含まれる"
        fi
        if [ "$scratch_mode" = list ]; then
            wt_snapshot "$wt"
            ledger_plan "scratch_worktrees $wt $(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null || true)" \
                worktree "$wt" "$why" "$wt_restore" "$wt_lost" || log "WARN: 台帳に予定を書けない $CLEANUP_LEDGER"
            log "PLAN  $wt ($why)"
            continue
        fi
        mark_stale "$wt" "$why" "$main"
    done
fi

# ---- worktree を消す。ブランチは残るのでコミットは失われない ----
# 消せたものだけを removed に入れ、compose を落とす対象はここから決める。
# 候補の段階で落とすと、削除が拒否された worktree の環境だけが毎時壊れる。
removed=()
i=0
for wt in ${removable[@]+"${removable[@]}"}; do
    why=${removable_why[$i]}
    main=${removable_main[$i]}
    i=$((i + 1))
    # 判定から削除までに Orca の節 (fetch と gh) で数分空くので、Orca の節と同じく compose を止める前に取り直す。
    if is_dirty "$wt"; then
        log "keep  $wt (削除直前に未コミットの変更を検出)"
        continue
    fi
    cwd_snapshot
    if [ "$cwds_ok" = "0" ] || in_use "$wt"; then
        log "keep  $wt (削除直前に、cwd がこの中にあるプロセスを検出、または lsof で取れない)"
        continue
    fi
    # scratchpad の worktree を作ったエージェントの cwd は scratchpad の外に在り、上の取り直しでは見えないので、lock と持ち主のセッションも取り直す。
    # 無視されるファイルも取り直す (上の is_dirty は見ず、git worktree remove は無視されるファイルごと消す)。
    if [ "${why#scratch_worktrees: }" != "$why" ]; then
        sid=$(scratch_sid "$wt") || sid=""
        if [ -z "$sid" ] || ! wt_unlocked "$main" "$wt" || ! scratch_owners || grep -qxF -- "$sid" <<<"$owners"; then
            log "keep  $wt (削除直前に、lock または持ち主のセッションを検出、または取れない)"
            continue
        fi
        if ! ig=$(ignored_unknown "$wt"); then
            log "keep  $wt (削除直前に git status --ignored 失敗)"
            continue
        fi
        if [ -n "$ig" ]; then
            log "keep  $wt (削除直前に、無視されるファイル: $ig が IGNORED_OK に無い)"
            continue
        fi
    fi
    wt_snapshot "$wt"
    stop_stacks "$wt" || continue
    if run git -C "$main" worktree remove "$wt" 2>/dev/null; then
        log "removed $wt"
        removed+=("$wt")
        record_removed "$wt" "$why"
    else
        log "WARN: remove 失敗 $wt"
        # 登録が外れて残ったフォルダがあると git worktree add は already exists で通らないので、先に退けてもらう。
        if wt_broken "$wt" "$main"; then
            record worktree-remove-failed "$wt" "$why (削除が途中で失敗し、登録だけ外れた)" ": 残ったフォルダを退けてから; $wt_restore" "$wt_lost"
        fi
        restart_stacks "$wt"
    fi
done

# git worktree prune は、外す登録を、その worktree の HEAD と reflog ごと消す。登録を選べない (リポ単位)。
# 外す登録は prune --dry-run -v の「Removing worktrees/<名前>: <理由>」で見る。worktree list --porcelain の prunable は、
# gitdir が無い・空の登録と、同じパスの重複を出さない。detached の HEAD がどのブランチ・リモート追跡ブランチ・タグからも
# 辿れない登録が 1 つでも在れば、そのコミットへの最後の参照を消しうるので、リポごと見送って 1 を返す (残すなら
# git branch <名前> <SHA>、要らなければ手で prune)。人が決めるまで毎時見送り続けるので、黙って止まらないよう 1 日 1 回知らせる。
# 一覧・dry-run が失敗した回、読めない行や HEAD が在った回も、何が外れるか分からないので見送る。
prune_safe() { # prune_safe <本体>
    local main="$1" dry common line name head wt out hit=0
    if ! git -C "$main" worktree list --porcelain >/dev/null 2>&1; then
        log "keep  $main (prune 見送り: git worktree list が失敗)"
        return 1
    fi
    # 文言はロケールで訳される (de・fr で確かめた)。出力は stderr。
    if ! dry=$(LC_ALL=C git -C "$main" worktree prune --dry-run -v 2>&1) ||
        ! common=$(git -C "$main" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
        log "keep  $main (prune 見送り: git worktree prune --dry-run が失敗)"
        return 1
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        head=""
        case "$line" in
            "Removing worktrees/"?*": "*)
                name=${line#Removing worktrees/}
                name=${name%%: *}
                # HEAD のファイルは reftable では置き石 (ref: refs/heads/.invalid) なので、git に解決させる。ブランチは対象外。
                if git -C "$main" symbolic-ref -q "worktrees/$name/HEAD" >/dev/null 2>&1; then continue; fi
                head=$(git -C "$main" rev-parse --verify -q "worktrees/$name/HEAD" 2>/dev/null) || head="" ;;
        esac
        if [ -z "$head" ]; then
            log "keep  $main (prune 見送り: 読めない行か HEAD: $line)"
            hit=1
            continue
        fi
        # 失敗も「辿れない」とみなす。
        out=$(git -C "$main" for-each-ref --contains "$head" refs/heads refs/remotes refs/tags 2>/dev/null) || out=""
        [ -z "$out" ] || continue
        wt=$(sed 's#/\.git$##' "$common/worktrees/$name/gitdir" 2>/dev/null) || wt=""
        log "keep  $main (prune 見送り: ${wt:-worktrees/$name} の detached HEAD $head がどの ref にも無い)"
        hit=1
    done <<<"$dry"
    [ "$hit" = 1 ] || return 0
    notify_daily "$STATE_ROOT/worktree-gc/prune-skipped-warned" \
        "$main の git worktree prune を見送っています。detached の HEAD にだけ在るコミットか、読めない登録がある (ログに)"
    return 1
}
if prune_safe "$REPO"; then run git -C "$REPO" worktree prune; fi

# ---- Orca の worktree を消す ----
# 判定から削除までに fetch や gh で数分空くので、直前に状態を取り直す。
if [ ${#orca_removable[@]} -gt 0 ] && ! ps_now=$(orca_ps); then
    log "WARN: 削除直前の orca worktree ps が取れない。Orca の worktree の削除は見送る (次回に拾う)"
    orca_removable=()
fi
i=0
for wt in ${orca_removable[@]+"${orca_removable[@]}"}; do
    why=${orca_why[$i]}
    i=$((i + 1))
    if is_dirty "$wt"; then
        log "keep  $wt (削除直前に未コミットの変更を検出)"
        continue
    fi
    busy=$(agents_busy "$wt" "$ps_now")
    if [ -n "$busy" ]; then
        log "keep  $wt (削除直前にエージェントが $busy)"
        continue
    fi
    if pinned "$wt" "$ps_now"; then
        log "keep  $wt (削除直前に Orca でピン留め)"
        continue
    fi
    # 1 つ消すのに 1 分かかることがあるので、worktree ごとに取り直す。判定で放置されたシェルだけと出たもの (規則が
    # idle_shell: で始まる) は、取り直しても放置されたシェルだけなら使用中に数えない。ほかは PR が閉じてからの時間を
    # 見ていないので、中にプロセスが 1 つでも居れば残す。
    cwd_snapshot
    if [ "$cwds_ok" = "0" ] || { in_use "$wt" && ! { [ "${why#idle_shell: }" != "$why" ] && idle_only "$wt"; }; }; then
        log "keep  $wt (削除直前に、cwd がこの中にあるプロセスを検出、または lsof で取れない)"
        continue
    fi
    wt_snapshot "$wt"
    stop_stacks "$wt" || continue
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY-RUN: orca worktree rm --worktree path:$wt"
        removed+=("$wt")
        continue
    fi
    if orca worktree rm --worktree "path:$wt" --json 2>/dev/null | jq -e '.ok == true' >/dev/null; then
        removed+=("$wt")
        record_removed "$wt" "$why" "Orca のカード (git worktree add で戻しても Orca の一覧には戻らない)"
        # 削除はバックグラウンドで続くことがある。1 分待っても残るフォルダはログに出す。
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
            [ -d "$wt" ] || break
            sleep 5
        done
        if [ -d "$wt" ]; then log "WARN: orca rm 後もフォルダが残っている $wt"; else log "removed $wt"; fi
    else
        log "WARN: orca rm 失敗 $wt"
        restart_stacks "$wt"
    fi
done

# ---- 消した worktree と孤児の compose プロジェクトを落とす ----
# パイプの while はサブシェルで回り、台帳の件数 (recorded) が通知まで届かないので、プロセス置換で読む。
if docker info >/dev/null 2>&1; then
    while IFS=$'\t' read -r proj dir; do
        [ -n "$proj" ] && [ -n "$dir" ] || continue

        # 消した worktree のプロジェクトは名前を問わず、名前付きボリュームごと落とす
        # (`docker volume prune` は匿名ボリュームしか消さず、worktree ごとに積み上がる)。
        reason=""
        for wt in ${removed[@]+"${removed[@]}"}; do
            case "$dir" in "$wt"|"$wt"/*) reason="削除した worktree $wt に属する" ;; esac
        done
        if [ -n "$reason" ]; then
            # 当たるものを中に持つ worktree は stop_stacks が残す (docker に届かない回も、名前の行があれば残す)。
            # ここで当たるのは、stop の時点で docker に届かず名前の行も無かった (パスの行が working_dir に当たる) か、
            # その後に現れたプロジェクトだけ。
            if kept_stack "$proj" "$dir"; then continue; fi
            log "down  $proj — $reason (ボリュームも削除)"
            vols=$(stack_volumes "$proj")
            if run docker compose -p "$proj" down --remove-orphans --volumes; then
                record compose-down "$proj" "$reason" ": worktree を戻してから; cd $(printf %q "$dir") && docker compose -p $(printf %q "$proj") up -d" "${vols:+volume: $vols (down --volumes で消える)}"
            else
                log "WARN: down 失敗 $proj"
            fi
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
        if kept_stack "$proj" "$dir"; then continue; fi

        log "down  $proj — working_dir が既に無い (孤児)"
        if run docker compose -p "$proj" down --remove-orphans; then
            # working_dir が無いので戻し方は書けない。名前付き volume は残すが、コンテナは down で、匿名 volume は
            # 下の docker volume prune で消える。
            record compose-down "$proj" "working_dir $dir が既に無い (孤児)" "" "コンテナと匿名 volume (直後の docker volume prune で消える)"
        else
            log "WARN: down 失敗 $proj"
        fi
    done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' | sort -u)
else
    log "WARN: docker が動いていない。コンテナの掃除はスキップ (次回、孤児として拾う)"
fi

# 何か止めたか消した回だけ、種類ごとの件数を 1 本で知らせる。中身は台帳 (zsh の別名 cleanup-ledger) で見る。
# 台帳に書く処理はここまでで終わるので、後ろのディスク回収より先に出す (回収の途中で落ちても、知らせは届く)。
if [ ${#recorded[@]} -gt 0 ]; then
    notify "$(printf '%s\n' "${recorded[@]}" | sort | uniq -c | awk '{ printf "%s%s %s 件", (NR > 1 ? "、" : ""), $2, $1 }')"
fi

# ---- ディスク回収 ----
if docker info >/dev/null 2>&1; then
    run docker image prune -f || true
    run docker volume prune -f || true
    run docker builder prune -f --filter "until=$BUILDER_CACHE_MAX_AGE" || true
    [ "$DRY_RUN" = "1" ] || log "prune 済み: dangling image / volume, build cache ($BUILDER_CACHE_MAX_AGE 超)"
    # 使用量はログの参考に出すだけ。取れなくても掃除は終わっているので、ここで落とさない。
    docker system df | sed 's/^/  /' || log "WARN: docker system df が失敗"
fi

log "=== 完了 (削除した worktree: ${#removed[@]}) ==="
