#!/usr/bin/env bash
# home/scripts/container-events.sh の記録を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/container-events.sh
#   /bin/bash tests/container-events.sh   # launchd と同じ bash 3.2 でスクリプトを動かす
# docker は偽物。本物の Docker には一切触らない (偽物は知らないサブコマンドを 1 で返す)。
# shellcheck disable=SC2016,SC2329  # '...' の中の $x は偽コマンドや awk の変数。check に渡す関数は間接的に呼ぶ
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/container-events.sh"
# 呼び出し元の設定を巻き込まない (手元に本物の ~/.config/container-events.env があっても、ここでは読まない)。
unset CONTAINERS KERNEL_LOG_IMAGE KERNEL_LOG_INTERVAL DOCKER_TIMEOUT
base=$(mktemp -d)
trap '[ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}

# ---- 偽の docker ----
mkdir -p "$base/bin"
# events は events.jsonl を流して終わる (接続が切れた扱い。終了コードは 0 にして、スクリプトが自分で 0 以外にすることを見る)。
# run は dmesg を出す。run-fail があれば、複数行のエラーを出して 1 で終わる。run-hang・info-hang があれば返らない
# (exec で眠る。bash の子に眠らせると、上限で KILL されても sleep が出力のパイプを握って $(…) が返らない)。
cat >"$base/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    events)
        echo "$*" >>"$FAKE/events-calls"; cat "$FAKE/events.jsonl"
        # hang があれば、流し終えても切れずに待ち続ける (常駐中に止められる場面)。
        [ -f "$FAKE/hang" ] && { echo $$ >"$FAKE/events.pid"; exec sleep 30; }
        exit 0 ;;
    run)
        echo "$*" >>"$FAKE/run-calls"
        [ -f "$FAKE/run-hang" ] && exec sleep 8
        if [ -f "$FAKE/run-fail" ]; then printf "Unable to find image 'alpine:3' locally\nsecond\tline\n" >&2; exit 1; fi
        cat "$FAKE/dmesg" ;;
    # info は Docker に繋がるかの確認。info-fail があれば繋がらない扱い。
    info) [ -f "$FAKE/info-hang" ] && exec sleep 8
        [ -f "$FAKE/info-fail" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }; exit 0 ;;
    *) echo "$*" >>"$FAKE/other-calls"; exit 1 ;;
esac
EOF
chmod +x "$base/bin/docker"

ev() { # ev <名前> <イベント> <終了コード> [<イメージ>]  docker events --format '{{json .}}' の 1 行 (moby の events.Message)
    jq -cn --arg n "$1" --arg a "$2" --arg c "$3" --arg i "${4:-img:1}" '
        {Type: "container", Action: $a, Actor: {ID: "abc", Attributes: ({name: $n, image: $i}
            + (if $c == "" then {} else {exitCode: $c, execDuration: "60"} end))},
         scope: "local", time: 1763340000, timeNano: 1763340000000000000}'
}

setup() {
    CASE=$1
    T="$base/$CASE"
    mkdir -p "$T/home"
    E="$T/home/Library/Application Support/container-events/events.tsv"
    : >"$T/events.jsonl"
    printf '%s\n' \
        '[    0.000000] Linux version 6.10.14-linuxkit' \
        '[ 1000.100000] app invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0' \
        '[ 1000.200000] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),task=app,pid=123,uid=999' \
        '[ 1000.300000] Out of memory: Killed process 123 (app) total-vm:4000000kB' \
        '[ 1000.400000] unrelated line' >"$T/dmesg"
}
# 設定と記録の場所は一時ディレクトリに向ける (手元の本物の設定・記録には触らない)。HOME は差し替えない
# (jq が mise の shim だと、HOME の下の mise の設定を読めずに落ちる)。
start() { # start [exec]  裏で動かすときは exec を渡し、$! をスクリプトの pid にする
    ${1:-} env STATE_ROOT="$T/home/Library/Application Support" CONTAINER_EVENTS_CONFIG="$T/config.env" \
        FAKE="$T" PATH="$base/bin:$PATH" "$BASH" "$script" >"$T/log" 2>&1
}
run() {
    start
    echo $? >"$T/rc"
}
rc() { cat "$T/rc"; }
row() { # row <名前> <イベント> <終了コード>  その 3 列の行があるか
    awk -F'\t' -v n="$1" -v e="$2" -v c="$3" '$2 == n && $3 == e && $4 == c { f = 1 } END { exit !f }' "$E"
}
rows() { awk -F'\t' -v e="$1" '$3 == e' "$E" | wc -l | tr -d ' '; }
first() { [ "$(head -1 "$E" | cut -f3)" = "$1" ]; }
last() { [ "$(tail -1 "$E" | cut -f3)" = "$1" ]; }
fields5() { [ -s "$E" ] && [ -z "$(awk -F'\t' 'NF != 5' "$E")" ]; }
nonzero() { [ "$(rc)" != 0 ]; }
is() { [ "$1" = "$2" ]; }
has() { grep -qF -- "$1" "$2"; }
# <コマンド> の出力が空。記録のファイルが無いときに通ってしまわないよう、ファイルがあることも見る (エラーも出力に数える)。
empty() { [ -s "$E" ] && [ -z "$("$@" 2>&1)" ]; }
kernels() { awk -F'\t' '$3 == "kernel" { print $5 }' "$E"; }

# README に書いた 137 の数え方を、書いた形のまま動かす。
count_cmd=$(grep -F "awk -F" "$root/README.md" | grep -F 'container-events/events.tsv')
count137() { (HOME="$T/home"; eval "$count_cmd"); }
CASE=readme
check "README に 137 の数え方が 1 行だけある" is 1 "$(printf '%s\n' "$count_cmd" | grep -c .)"

# ---- 対象のコンテナが 137 で落ちたら、その場でカーネルログを取る ----
setup die-137
echo 'CONTAINERS="db cache"' >"$T/config.env"
ev db die 137 >>"$T/events.jsonl"
run
check "最初の行が stream-start" first stream-start
check "die 137 の行がある" row db die 137
check "kernel の行はメモリ不足の 3 行だけ" is 3 "$(rows kernel)"
check "kernel の行に Killed process が入る" has "Out of memory: Killed process 123" "$E"
check "関係ない dmesg の行は残さない" empty grep -F 'Linux version' "$E"
check "最後の行が stream-end" last stream-end
check "切れたら 0 以外で終わる" nonzero
check "採取は 1 回だけ" is 1 "$(wc -l <"$T/run-calls" | tr -d ' ')"
check "採取は --pull=never" has "--pull=never" "$T/run-calls"
check "採取は --network none" has "--network none" "$T/run-calls"
check "採取は既定で alpine:3" has " alpine:3 dmesg" "$T/run-calls"
check "採取は --rm (止まったコンテナを残さない)" has "--rm" "$T/run-calls"
check "採取は --cap-add SYSLOG (無いと dmesg を読めない)" has "--cap-add SYSLOG" "$T/run-calls"
check "時刻はイベントの .time" is "$(jq -nr '1763340000 | todate')" "$(awk -F'\t' '$3 == "die" { print $1 }' "$E")"
check "die と oom だけを流す" has "--filter event=die --filter event=oom" "$T/events-calls"
check "137 を 1 と数える" is 1 "$(count137)"
check "どの行も 5 列" fields5

# ---- 0 で落ちたものと oom は記録するが、採取しない ----
setup die-0
echo 'CONTAINERS="db"' >"$T/config.env"
{
    echo 'not json {'
    ev db die 0
    ev db oom ""
} >>"$T/events.jsonl"
run
check "読めない行の後の行も記録する" row db die 0
check "読めない行はログに出す" has "読めない行を飛ばした" "$T/log"
check "die 0 の行がある" row db die 0
check "oom の行がある (終了コードは -)" row db oom -
check "採取は呼ばれない" test ! -e "$T/run-calls"
check "kernel の行は無い" is 0 "$(rows kernel)"
check "137 は 0 と数える" is 0 "$(count137)"

# ---- 対象でないコンテナは記録しない (名前は完全一致) ----
setup not-target
echo 'CONTAINERS="db"' >"$T/config.env"
{
    ev other die 137
    ev db2 die 137
    ev db die 1
} >>"$T/events.jsonl"
run
check "対象の行は記録される" row db die 1
check "other は記録しない" empty awk -F'\t' '$2 == "other"' "$E"
check "db2 は記録しない" empty awk -F'\t' '$2 == "db2"' "$E"
check "採取は呼ばれない" test ! -e "$T/run-calls"

# ---- 環境変数が設定ファイルに勝つ ----
setup env-wins
echo 'CONTAINERS="db"' >"$T/config.env"
{
    ev db die 1
    ev cache die 1
} >>"$T/events.jsonl"
CONTAINERS=cache run
check "環境変数の cache を記録する" row cache die 1
check "設定ファイルの db は記録しない" empty awk -F'\t' '$2 == "db"' "$E"

# ---- CONTAINERS が無ければ、何も書かずに 0 で終わる ----
setup unset
ev db die 137 >>"$T/events.jsonl"
run
check "終了コード 0" is 0 "$(rc)"
check "記録のファイルを作らない" test ! -e "$E"
check "docker events を呼ばない" test ! -e "$T/events-calls"
check "理由をログに 1 行出す" is 1 "$(grep -c . "$T/log")"

# ---- Docker に繋がらなければ、記録に何も書かずに 0 以外で終わる (launchd が間を空けて起こし直す) ----
setup no-docker
echo 'CONTAINERS="db"' >"$T/config.env"
ev db die 137 >>"$T/events.jsonl"
touch "$T/info-fail"
run
check "0 以外で終わる" nonzero
check "記録のファイルを作らない" test ! -e "$E"
check "docker events を呼ばない" test ! -e "$T/events-calls"
check "理由をログに出す" has "Docker に繋がらない" "$T/log"

# ---- 空の CONTAINERS は、設定ファイルにあっても未設定と同じ ----
setup empty
echo 'CONTAINERS="db"' >"$T/config.env"
CONTAINERS=" " run
check "終了コード 0" is 0 "$(rc)"
check "記録のファイルを作らない" test ! -e "$E"

# ---- 採取に失敗しても、補足に理由を書いて続ける ----
setup kernel-fails
echo 'CONTAINERS="db cache"' >"$T/config.env"
touch "$T/run-fail"
{
    ev db die 137
    ev cache die 137
} >>"$T/events.jsonl"
KERNEL_LOG_INTERVAL=0 run
check "後続の die も記録される" row cache die 137
check "採取は 2 回" is 2 "$(wc -l <"$T/run-calls" | tr -d ' ')"
check "kernel の行は 1 件ごとに 1 行" is 2 "$(rows kernel)"
check "kernel の補足に失敗と理由が出る" test -n "$(awk -F'\t' '$3 == "kernel" && $5 ~ /失敗/ && $5 ~ /Unable to find image/' "$E")"
check "最後の行が stream-end" last stream-end
check "137 を 2 と数える" is 2 "$(count137)"
check "どの行も 5 列" fields5

# ---- 値にタブや改行が入っても 1 件 1 行 ----
setup tabs
echo 'CONTAINERS="db"' >"$T/config.env"
ev db die 137 "$(printf 'img\twith\nnewline')" >>"$T/events.jsonl"
long=$(printf '%600s' '' | tr ' ' x)
printf '[ 1.0] Out of memory:\tKilled process 1 (a)\n[ 2.0] Killed process 2 %s\n' "$long" >"$T/dmesg"
run
check "どの行も 5 列" fields5
check "行数は start・die・kernel 2・end の 5" is 5 "$(wc -l <"$E" | tr -d ' ')"
check "kernel の 1 行は 500 字で切る" empty awk -F'\t' 'length($5) > 500' "$E"
check "長い kernel の行も残る" test -n "$(awk -F'\t' '$3 == "kernel" && $5 ~ /Killed process 2/' "$E")"

# ---- 採取が返らなくても、上限で諦めて記録を続ける ----
setup kernel-timeout
echo 'CONTAINERS="db"' >"$T/config.env"
touch "$T/run-hang"
{
    ev db die 137
    ev db die 1
} >>"$T/events.jsonl"
DOCKER_TIMEOUT=1 run
check "kernel の補足に時間切れの失敗が出る" test -n "$(kernels | grep -F '失敗' | grep -F '時間切れ')"
check "後ろの行も記録される" row db die 1
check "最後の行が stream-end" last stream-end
check "0 以外で終わる" nonzero

# ---- docker info が返らなければ、上限で 0 以外で終わる ----
setup info-timeout
echo 'CONTAINERS="db"' >"$T/config.env"
touch "$T/info-hang"
DOCKER_TIMEOUT=1 run
check "0 以外で終わる" nonzero
check "理由をログに出す" has "Docker に繋がらない" "$T/log"
check "docker events を呼ばない" test ! -e "$T/events-calls"

# ---- 記録に既に在るメモリ不足の行は、次の 137 に付けない (再起動をまたいでも) ----
# dmesg はバッファ全体を返すので、比べないと古い行 (別のプロセスのものも) が無関係な 137 に毎回付く。
setup kernel-seen
echo 'CONTAINERS="db cache"' >"$T/config.env"
# 突き合わせが record の整形 (タブ・\ のエスケープ、500 字) と食い違わないことも見る。
printf '[ 1.0] Out of memory:\tKilled process 1 (a\\b)\n[ 2.0] Killed process 2 %s\n' "$long" >>"$T/dmesg"
{
    ev db die 137
    ev cache die 137
} >>"$T/events.jsonl"
KERNEL_LOG_INTERVAL=0 run
check "1 回目はメモリ不足の 5 行" is 5 "$(kernels | grep -vc '新しいメモリ不足の行は無かった')"
check "2 回目は新しい行が無かったと書く" is 1 "$(kernels | grep -c '新しいメモリ不足の行は無かった')"
check "2 回目の kernel は 1 行だけ" is 6 "$(rows kernel)"
echo '[ 2000.100000] Out of memory: Killed process 456 (cache) total-vm:1kB' >>"$T/dmesg"
: >"$T/events.jsonl"
ev cache die 137 >>"$T/events.jsonl"
KERNEL_LOG_INTERVAL=0 run
check "足された行だけを書く" is 7 "$(rows kernel)"
check "足された行がある" is 1 "$(kernels | grep -c 'Killed process 456')"
check "古い行は 1 回だけ" is 1 "$(kernels | grep -c 'Killed process 123')"
check "どの行も 5 列" fields5

# ---- 新しい行が多くても切らない (切ると、落とした行が次の採取で新しい行として無関係な 137 に付く) ----
setup kernel-many
echo 'CONTAINERS="db cache"' >"$T/config.env"
for i in $(seq 15); do echo "[ 3000.$i] Killed process $i (p$i)"; done >"$T/dmesg"
{
    ev db die 137
    ev cache die 137
} >>"$T/events.jsonl"
KERNEL_LOG_INTERVAL=0 run
check "1 回目に 15 行全部が付く" is 15 "$(awk -F'\t' '$2 == "db" && $3 == "kernel"' "$E" | wc -l | tr -d ' ')"
check "2 回目は新しい行が無かったと書く" is "新しいメモリ不足の行は無かった" "$(awk -F'\t' '$2 == "cache" && $3 == "kernel" { print $5 }' "$E")"

# ---- 前の採取から間が無ければ、採取を省く ----
# メモリ不足の直後の VM に、同じ dmesg を取るためのコンテナを何度も載せないように。
setup throttle
echo 'CONTAINERS="db cache"' >"$T/config.env"
{
    ev db die 137
    ev cache die 137
} >>"$T/events.jsonl"
run
check "採取は 1 回" is 1 "$(wc -l <"$T/run-calls" | tr -d ' ')"
check "省いたと書く" is 1 "$(kernels | grep -c '採取を省いた')"
check "後ろの die も記録される" row cache die 137

# ---- - で始まる行も記録する (jq のオプションと取り違えない) ----
setup dash
echo 'CONTAINERS="db"' >"$T/config.env"
printf '%s\n' '-n Killed process 1 (a)' '--arg Killed process 2 (b)' >"$T/dmesg"
ev db die 137 >>"$T/events.jsonl"
run
check "-n の行がある" is 1 "$(kernels | grep -c -- '^-n Killed process 1')"
check "--arg の行がある" is 1 "$(kernels | grep -c -- '^--arg Killed process 2')"

# ---- CONTAINERS はタブ・改行で区切っても読む ----
setup separators
printf 'CONTAINERS="db\tcache\nweb"\n' >"$T/config.env"
{
    ev cache die 1
    ev web die 1
} >>"$T/events.jsonl"
run
check "タブの後の名前を記録する" row cache die 1
check "改行の後の名前を記録する" row web die 1
check "stream-start の対象は空白区切り" has "対象: db cache web" "$E"

# ---- 記録の置き場所を作れなければ、docker events を始めずに 0 以外で終わる ----
setup no-dir
echo 'CONTAINERS="db"' >"$T/config.env"
mkdir -p "$T/home/Library"
: >"$T/home/Library/Application Support"
run
check "0 以外で終わる" nonzero
check "docker events を呼ばない" test ! -e "$T/events-calls"
check "理由をログに出す" has "書けない" "$T/log"

# ---- 最初の行を書けなくても同じ ----
setup no-write
echo 'CONTAINERS="db"' >"$T/config.env"
mkdir -p "$E"
run
check "0 以外で終わる" nonzero
check "docker events を呼ばない" test ! -e "$T/events-calls"
check "理由をログに出す" has "書けない" "$T/log"

# ---- .time の無い行は今の時刻にする ----
setup no-time
echo 'CONTAINERS="db"' >"$T/config.env"
ev db die 1 | jq -c 'del(.time)' >>"$T/events.jsonl"
run
check "die の行がある" row db die 1
check "時刻は今年" is "$(date -u +%Y)" "$(awk -F'\t' '$3 == "die" { print substr($1, 1, 4) }' "$E")"

# ---- 流している最中に止められたら (ログアウト・kickstart -k)、その時点で stream-end を書く ----
setup stopped
echo 'CONTAINERS="db"' >"$T/config.env"
ev db die 137 >>"$T/events.jsonl"
touch "$T/hang"
start exec &
sp=$!
for _ in $(seq 50); do [ "$(rows kernel 2>/dev/null)" = 3 ] && break; sleep 0.1; done
check "ストリームが開いたまま採取する" is 3 "$(rows kernel)"
kill "$sp"
# 終わらなければ 5 秒で KILL する (そのときの終了コードは 137 になり、下の検査で落ちる)。
(sleep 5; kill -9 "$sp" 2>/dev/null) &
wd=$!
wait "$sp"
echo $? >"$T/rc"
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
check "止めたらすぐ 143 で終わる" is 143 "$(rc)"
check "最後の行が stream-end" last stream-end
check "stream-end に止められたと書く" test -n "$(tail -1 "$E" | grep -F '停止')"
# 止めた後に孤児で残っていないか (ゾンビは kill -0 に応えるので ps の状態で見る)。
alive() { s=$(ps -o stat= -p "$1" 2>/dev/null) && [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
check "docker events も止める" test -z "$(alive "$(cat "$T/events.pid")" && echo alive)"
kill "$(cat "$T/events.pid" 2>/dev/null)" 2>/dev/null

[ "$fail" = 0 ] && echo "ok: container-events"
exit "$fail"
