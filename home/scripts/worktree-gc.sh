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
DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# 止めた・消したものの台帳。launchd は origin/main の写しを動かすので、隣のこのファイルも同じ版になる。
# shellcheck source=home/scripts/cleanup-ledger.sh
. "$(dirname "${BASH_SOURCE[0]}")/cleanup-ledger.sh"

notify() {
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "worktree-gc"' -e 'end run' "$*" >/dev/null 2>&1 || true
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
wt_broken() {
    local list
    [ -e "$1/.git" ] || return 0
    # 一覧を取れない回は登録が外れたか分からないので、壊れていないとみなす (分からないことを台帳に書かない)。
    # パイプの grep -q は git を SIGPIPE で落とし、pipefail で「登録が無い」に化けうるので、出力を受けてから探す。
    list=$(git -C "$REPO" worktree list --porcelain 2>/dev/null) || return 1
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
mark_stale() {
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
# この worktree のプロジェクト名は stacks (改行区切り。名前に空白があっても割れない) に、台帳に書く volume の名前は
# stack_vols に入れる。
stop_stacks() {
    local wt="$1" proj dir id v
    running=() stacks="" stack_vols=""
    docker info >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r proj dir; do
        [ -n "$proj" ] && [ -n "$dir" ] || continue
        case "$dir" in "$wt"|"$wt"/*) ;; *) continue ;; esac
        case $'\n'"$stacks" in *$'\n'"$proj"$'\n'*) continue ;; esac
        stacks+="$proj"$'\n'
        v=$(stack_volumes "$proj")
        if [ -n "$v" ]; then stack_vols="${stack_vols:+$stack_vols / }$proj: $v"; fi
        while read -r id; do [ -n "$id" ] && running+=("$id"); done \
            < <(docker ps -q --filter "label=com.docker.compose.project=$proj")
        log "stop  $proj — $wt を消す前に止める"
        run docker compose -p "$proj" stop || log "WARN: stop 失敗 $proj"
    done < <(docker ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' | sort -u)
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
removable=() removable_why=()
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
orca_removable=() orca_why=()

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
        why="$branch: PR #$num が $(jq -r 'max_by(.number) | .state' <<<"$prs")"
        log "STALE $wt ($why$(ignored_note "$wt"))"
        orca_removable+=("$wt")
        orca_why+=("$why")
    done < <(orca worktree list --json 2>/dev/null | jq -r --arg root "$ORCA_ROOT" '
        .result.worktrees[]?
        | select((.isMainWorktree | not) and (.path | startswith($root + "/")))
        | [.path, ((.branch // "") | sub("^refs/heads/"; ""))] | @tsv')
fi

# ---- worktree を消す。ブランチは残るのでコミットは失われない ----
# 消せたものだけを removed に入れ、compose を落とす対象はここから決める。
# 候補の段階で落とすと、削除が拒否された worktree の環境だけが毎時壊れる。
removed=()
i=0
for wt in ${removable[@]+"${removable[@]}"}; do
    why=${removable_why[$i]}
    i=$((i + 1))
    wt_snapshot "$wt"
    stop_stacks "$wt"
    if run git -C "$REPO" worktree remove "$wt" 2>/dev/null; then
        log "removed $wt"
        removed+=("$wt")
        record_removed "$wt" "$why"
    else
        log "WARN: remove 失敗 $wt"
        # 登録が外れて残ったフォルダがあると git worktree add は already exists で通らないので、先に退けてもらう。
        if wt_broken "$wt"; then
            record worktree-remove-failed "$wt" "$why (削除が途中で失敗し、登録だけ外れた)" ": 残ったフォルダを退けてから; $wt_restore" "$wt_lost"
        fi
        restart_stacks "$wt"
    fi
done
run git -C "$REPO" worktree prune

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
    # 1 つ消すのに 1 分かかることがあるので、worktree ごとに取り直す。
    cwd_snapshot
    if [ "$cwds_ok" = "0" ] || in_use "$wt"; then
        log "keep  $wt (削除直前に、cwd がこの中にあるプロセスを検出、または lsof で取れない)"
        continue
    fi
    wt_snapshot "$wt"
    stop_stacks "$wt"
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
