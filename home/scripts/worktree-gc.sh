#!/usr/bin/env bash
#
# studio-api の worktree と、それに紐づく docker compose プロジェクトを掃除する。
# launchd から 1 日 2 回 (12:00 / 21:00) 実行される。定義は home/worktree-gc.nix。
#
# 手で確認するとき:
#   DRY_RUN=1 ~/www/dotfiles/home/scripts/worktree-gc.sh
#
set -euo pipefail

# launchd の PATH は /usr/sbin:/usr/bin:/sbin:/bin だけで、docker も nix の git も入らない。
# ここで通さないとジョブが黙って何もせず終わる。
PATH="/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

REPO="${REPO:-$HOME/www/dev/app}"
# 削除の全条件に効かせる最終ガード。稼働中のエージェントが作った直後の worktree は
# 「detached・clean・origin/dev と同一」で内容ベースの判定を全部すり抜けるため、
# 新しいものは一律で見送る (次の実行で拾える)。
MIN_AGE_HOURS="${MIN_AGE_HOURS:-24}"
# down / remove の対象にする compose プロジェクト名の接頭辞。共有インフラ (mysql,
# traefik...) や他リポジトリ (docker-*, studio-*) と、本体の `app` を巻き込まないための境界。
PROJECT_PREFIXES="app-app- app-worktree-"
# build cache はここより古いものだけ捨てる。image は dangling のみ (-a を付けると
# api-base が毎日消えて make build のたびに再 pull になる)。
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
    log "STALE $wt ($why)"
    removable+=("$wt")
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

[ -d "$REPO" ] || { log "repo が無い: $REPO"; exit 0; }

log "=== worktree-gc 開始 (repo=$REPO dry_run=$DRY_RUN) ==="

# upstream が消えたか (= PR が merge/close された) を見るために必要。
# オフライン時はこの判定だけ諦めて、孤児の掃除は続ける。
fetch_ok=1
git -C "$REPO" fetch --prune --quiet 2>/dev/null || { fetch_ok=0; log "WARN: fetch 失敗。upstream-gone 判定はスキップする"; }

# ---- 削除してよい worktree を選ぶ ----
removable=()
while read -r wt; do
    [ "$wt" = "$REPO" ] && continue

    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
        log "keep  $wt (未コミットの変更あり)"
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
        # detached。origin/dev から辿れる = 固有のコミットを持たない使い捨て。
        if git -C "$wt" merge-base --is-ancestor HEAD origin/dev 2>/dev/null; then
            mark_stale "$wt" "detached: origin/dev に含まれる"
        else
            log "keep  $wt (detached: origin/dev に無いコミットを持つ)"
        fi
    fi
done < <(git -C "$REPO" worktree list --porcelain | awk '/^worktree /{print $2}')

# ---- 対象 worktree と孤児の compose プロジェクトを落とす ----
if docker info >/dev/null 2>&1; then
    docker ps -a --format '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}' \
        | sort -u | while IFS=$'\t' read -r proj dir; do
        [ -n "$proj" ] || continue

        matched=0
        for prefix in $PROJECT_PREFIXES; do
            case "$proj" in "$prefix"*) matched=1 ;; esac
        done
        [ "$matched" = "1" ] || continue

        reason=""
        if [ ! -d "$dir" ]; then
            reason="working_dir が既に無い (孤児)"
        else
            for wt in ${removable[@]+"${removable[@]}"}; do
                case "$dir" in "$wt"|"$wt"/*) reason="削除対象 worktree $wt に属する" ;; esac
            done
        fi
        [ -n "$reason" ] || continue

        log "down  $proj — $reason"
        run docker compose -p "$proj" down --remove-orphans || log "WARN: down 失敗 $proj"
    done
else
    log "WARN: docker が動いていない。コンテナの掃除はスキップ (次回、孤児として拾う)"
fi

# ---- worktree を消す。ブランチは残るのでコミットは失われない ----
for wt in ${removable[@]+"${removable[@]}"}; do
    if run git -C "$REPO" worktree remove "$wt" 2>/dev/null; then
        log "removed $wt"
    else
        log "WARN: remove 失敗 $wt"
    fi
done
run git -C "$REPO" worktree prune

# ---- ディスク回収 ----
if docker info >/dev/null 2>&1; then
    run docker image prune -f || true
    run docker volume prune -f || true
    run docker builder prune -f --filter "until=$BUILDER_CACHE_MAX_AGE" || true
    [ "$DRY_RUN" = "1" ] || log "prune 済み: dangling image / volume, build cache ($BUILDER_CACHE_MAX_AGE 超)"
    docker system df | sed 's/^/  /'
fi

log "=== 完了 (削除した worktree: ${#removable[@]}) ==="
