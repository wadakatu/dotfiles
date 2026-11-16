#!/usr/bin/env bash
#
# 指定したコンテナの die / oom を、落ちたその場で記録し続ける。
# Docker はコンテナを起動し直すたびに State.ExitCode と State.OOMKilled を戻すので、restart policy で戻ったものは
# 後から docker inspect しても落ちた理由が残らない。VM のカーネルログもメモリ不足 1 回分で埋まり、次の回で上書きされる。
# docker events は過去の時間帯を引き直しても返らなかったので、常時流しておく。
# launchd が常駐させる (KeepAlive)。定義は home/container-events.nix。
#
# 記録は events.tsv にタブ区切りで 1 行 1 件: 時刻 (UTC, ISO 8601)、コンテナ名、イベント、終了コード、補足。
# イベントは die・oom のほか、kernel (die 137 のときに取ったカーネルログの行)、stream-start・stream-end
# (この間しか記録していない。end から次の start までのイベントは取れていない)。空の欄は -。
#
set -u

# launchd の PATH には docker も nix の jq も無い。worktree-gc.sh と同じく後ろに足す (テストが偽の docker を前に差せるように)。
PATH="$PATH:/etc/profiles/per-user/${USER}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# どのコンテナを見るかは公開リポに置かず、手元の設定ファイルで渡す (worktree-gc.sh と同じ作法)。環境変数で渡した値が勝つ。
#   CONTAINERS="名前 名前"       対象のコンテナ名 (空白区切り、完全一致)
#   KERNEL_LOG_IMAGE=alpine:3   カーネルログを取る使い捨てコンテナのイメージ (ローカルにあるものだけ使う)
#   KERNEL_LOG_INTERVAL=60      前の採取からこの秒数の内側の 137 では採取しない
#   DOCKER_TIMEOUT=20           docker info と採取の docker run を待つ上限 (秒、1 以上)
CONFIG="${CONTAINER_EVENTS_CONFIG:-$HOME/.config/container-events.env}"
_env="$(declare -p CONTAINERS KERNEL_LOG_IMAGE KERNEL_LOG_INTERVAL DOCKER_TIMEOUT 2>/dev/null || true)"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"
eval "$_env"
# タブ・改行で区切られていても読めるよう、空白類を 1 つの空白に揃える (jq の側は空白で割る)。
CONTAINERS=$(printf '%s' "${CONTAINERS:-}" | tr -s '[:space:]' ' ')
KERNEL_LOG_IMAGE="${KERNEL_LOG_IMAGE:-alpine:3}"
KERNEL_LOG_INTERVAL="${KERNEL_LOG_INTERVAL:-60}"
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-20}"
STATE_ROOT="${STATE_ROOT:-$HOME/Library/Application Support}"
OUT="$STATE_ROOT/container-events/events.tsv"
# 採取用のコンテナに付ける。人や掃除のスクリプトが、どこから来たコンテナか見分けられるように。
LABEL="dotfiles.container-events=kernel-log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
# with_timeout <秒> <コマンド...>  時間切れなら KILL して 124 で返す。macOS に timeout コマンドがあるとは限らないので perl で。
# alarm して exec する形は docker に効かない (Go のランタイムは SIGALRM を受けても終わらない) ので、子を fork して殺す。
with_timeout() {
    perl -e '$t = shift; $p = fork; if (!$p) { exec @ARGV; exit 127 } $SIG{ALRM} = sub { kill "KILL", $p }; alarm $t; waitpid $p, 0; exit($? & 127 ? 124 : $? >> 8)' "$@"
}

# record <名前> <イベント> <終了コード> <補足>
# どの値もタブ・改行を @tsv でエスケープし、500 字で切る (1 件が必ず 1 行・5 列になるように)。
record() {
    jq -rn --arg t "$(now)" '[$t] + $ARGS.positional | map(if . == "" then "-" else .[0:500] end) | @tsv' \
        --args -- "$@" >>"$OUT"
}

if [ -z "${CONTAINERS// /}" ]; then
    log "CONTAINERS が未設定 ($CONFIG)。何も記録しない"
    exit 0
fi
# Docker が止まっている間は、記録に stream-start・stream-end の組を積まずに終わる (記録していない区間は、
# 前の stream-end から次の stream-start までで読める)。0 以外で終わり、launchd に間を空けて起こし直させる。
# 固まったデーモンで黙って止まらないよう、上限を付ける。
with_timeout "$DOCKER_TIMEOUT" docker info >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    log "Docker に繋がらない (exit ${rc}、124 は ${DOCKER_TIMEOUT} 秒で時間切れ)。次の起動で確かめ直す"
    exit 1
fi

# 137 で落ちた直後に、VM のカーネルログからメモリ不足の行だけを取る (次のメモリ不足で上書きされる前に)。
# --pull=never: 落ちた直後の詰まった VM にイメージの取得まで載せない。無ければ諦めて理由を残す。
# 失敗してもストリームは止めない。stdin を閉じるのは、イベントの読み取りを横取りさせないため。
# 返らないと読み取りが止まり、記録も黙って止まるので上限を付ける。
kernel_log() {
    local name="$1" out rc why lines
    out=$(with_timeout "$DOCKER_TIMEOUT" docker run --rm --pull=never --network none --cap-add SYSLOG --label "$LABEL" \
        "$KERNEL_LOG_IMAGE" dmesg </dev/null 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        why="exit $rc"
        [ "$rc" = 124 ] && why="${DOCKER_TIMEOUT} 秒で時間切れ"
        record "$name" kernel "" "カーネルログの採取に失敗 ($why): $out"
        return 0
    fi
    # dmesg はバッファ全体を返すので、記録に既に在る行 (前の採取で書いた古いメモリ不足) は書かない。無関係な 137 に
    # 古い行が付かないように。行頭の時刻では比べない (VM が再起動すると 0 に戻る)。比べる形は record と同じ jq の
    # 整形 (500 字で切って @tsv) で作る (シェルで切るとバイトと文字でずれる)。行数の上限は付けない (切ると、落とした
    # 行が次の採取で新しい行として無関係な 137 に付く)。初回はバッファに残っている行が全部書かれる。
    lines=$(printf '%s\n' "$out" | grep -E 'Out of memory|oom-kill|Killed process' |
        jq -nRr --rawfile seen "$OUT" '
            ([$seen | split("\n")[] | split("\t") | select(.[2] == "kernel") | {(.[4]): true}] | add // {}) as $old
            | inputs | select($old[[.[0:500]] | @tsv] | not)')
    if [ -z "$lines" ]; then
        record "$name" kernel "" "新しいメモリ不足の行は無かった"
        return 0
    fi
    printf '%s\n' "$lines" | while IFS= read -r l; do record "$name" kernel "" "$l"; done
}

# 1 行の JSON (moby の events.Message) を、先頭に「採取するか」の欄を付けた TSV にする。対象外なら何も出さない。
# 空の欄は record と同じく - にする (awk や cut で読む人が、欠けた欄と区切りを取り違えないように)。
to_row() {
    jq -r --arg names "$CONTAINERS" '
        (.Actor.Attributes // {}) as $a
        | select(any($names | split(" ")[]; . != "" and . == $a.name))
        | [ (if .Action == "die" and $a.exitCode == "137" then "1" else "0" end),
            (.time // (now | floor) | todate), $a.name, .Action, ($a.exitCode // ""),
            ([ "image=\($a.image // "")", ($a.execDuration // empty | "execDuration=\(.)s") ] | join(" ")) ]
        | map(if . == "" then "-" else .[0:500] end) | @tsv
    '
}

end_stream() {
    record "" stream-end "" "$1"
    log "stream-end: $1"
}
# launchd が止めたとき (ログアウト・kickstart -k) も、記録していない区間の始まりを残す。
# bash は前面のコマンドが終わるまで trap を走らせないので、ストリームは裏で回して wait で待つ (wait は合図で抜ける)。
# 裏のパイプライン (docker events と読み取り) はこのシェルの子なので、pkill -P で一緒に止める。
# 先に止めるのは、止めるまでに届いた行が stream-end の後ろに書かれないように。
trap 'pkill -P $$ 2>/dev/null; end_stream "停止の合図を受けた"; exit 143' TERM INT HUP

tab=$(printf '\t')
# 書けないまま流すと、何も残さずに常駐し続ける。0 以外で終わり、理由をログに残す。
if ! mkdir -p "$(dirname "$OUT")" || ! record "" stream-start "" "対象: $CONTAINERS"; then
    log "記録に書けない ($OUT)。docker events を始めない"
    exit 1
fi
log "stream-start: $CONTAINERS"
# イベントは稀なので 1 行ずつ jq に通す。パイプでまとめると jq の出力が溜まり、137 の採取がその場で走らない。
# 採取は前の採取 (失敗・時間切れも含む) から KERNEL_LOG_INTERVAL 秒は省く。一斉に落ちたときに同じ dmesg を何度も取り、
# メモリ不足の直後の VM にコンテナを重ねないように。省いた間の行は、次の採取で新しい行として拾う。
last_sample=
docker events --filter event=die --filter event=oom --format '{{json .}}' | while IFS= read -r line; do
    row=$(printf '%s\n' "$line" | to_row 2>/dev/null) || {
        log "読めない行を飛ばした: $line"
        continue
    }
    [ -n "$row" ] || continue
    printf '%s\n' "${row#*"$tab"}" >>"$OUT"
    if [ "${row%%"$tab"*}" = 1 ]; then
        name=$(printf '%s\n' "$row" | cut -f3)
        if [ -n "$last_sample" ] && [ $((SECONDS - last_sample)) -lt "$KERNEL_LOG_INTERVAL" ]; then
            record "$name" kernel "" "採取を省いた (前の採取から $((SECONDS - last_sample)) 秒)"
        else
            last_sample=$SECONDS
            kernel_log "$name"
        fi
    fi
done &
wait $!
trap - TERM INT HUP
# docker events は自分からは終わらない。終わったのは Docker に繋がらない・Docker が止まった、なので
# 0 以外で終わって launchd に起こし直させる (ThrottleInterval で間を空ける)。理由は docker の stderr (ログ) に出る。
end_stream "docker events が終わった"
exit 1
