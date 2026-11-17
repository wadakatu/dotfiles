#!/usr/bin/env bash
#
# 掃除ジョブが共有する関数。各スクリプトが自分と同じディレクトリから source する。
#   . "$(dirname "${BASH_SOURCE[0]}")/cleanup-ledger.sh"
#   ledger_add <種類> <対象> <当たった規則> <戻し方のコマンド> <戻らないもの>
#   keep_load || <この回は何も止めず何も消さない>   # 呼び側で log を定義しておく
#   if keep_match <対象>...; then <残す>; fi
#   mode=$(rule_mode <規則名>)   # off / list / on。呼び側で log を定義しておく
# launchd からは /bin/bash (3.2) で動くので、連想配列などの bash 4 以降の機能は使わない。
#
# ---- 台帳 ----
# ログは毎時の「残した理由」に埋もれ、ブランチやセッションも残らない。後から「何が消えたか」「どう戻すか」を
# 引けるよう、消したものだけを別のファイルに残す。直近は zsh の別名 cleanup-ledger で表にして見る。
#
# 台帳はタブ区切り・追記のみ。列は 時刻 (ISO 8601、ローカル時刻) / 種類 / 対象 / 当たった規則 / 戻し方 / 戻らないもの。
# 列は後ろに足すだけにする (並べ替えない、途中に挟まない)。LaunchAgent は origin/main の写しを、手で打つ agent-gc は
# checkout を動かすので、同じ台帳に版の違う関数が書く。後ろに足すだけなら、古い版の行は末尾の列が欠けるだけで読める。
#
# 置き場所は dispatch-lock.sh と同じく STATE_ROOT から決める。テストはこの 1 つを一時ディレクトリに向ける。
STATE_ROOT="${STATE_ROOT:-$HOME/Library/Application Support}"
CLEANUP_LEDGER="$STATE_ROOT/cleanup-ledger/ledger.tsv"

ledger_add() {
    local line f
    line=$(date '+%Y-%m-%dT%H:%M:%S%z')
    # 値の中のタブ・改行・CR は空白にする。タブと改行は 1 件を別の列や別の行に割り、CR は端末の表示で行頭に戻って前を隠す。
    for f in "$@"; do
        f=${f//$'\t'/ }
        f=${f//$'\r'/ }
        line="$line"$'\t'"${f//$'\n'/ }"
    done
    mkdir -p "${CLEANUP_LEDGER%/*}" && printf '%s\n' "$line" >>"$CLEANUP_LEDGER"
}

# ---- 「触らない」リスト ----
# 追跡しないローカルの設定 (公開リポに置けないパスや名前を書くため)。1 行 1 つで、# の行と空行は読み飛ばす。
# / か ~・~/ で始まる行はパスの接頭辞、それ以外は名前 (compose project など) の完全一致。正規表現・glob は使わない
# (打ち間違いの . や * が思わぬものに当たると、守ったつもりのものが消える)。解釈できない行が 1 つでもあれば読めない扱い。
# ファイルが無い・読めないとき、呼び側はその回は何も止めず何も消さない。守るものが無いことは空のファイルで表す
# (消えたファイルを「守るものが無い」と読むと、守っていたものを全部消す)。
CLEANUP_KEEP="${CLEANUP_KEEP:-$HOME/.config/cleanup-keep}"
# 読んだ行。パスは p:<パス>、名前は n:<名前> の形で改行区切り (bash 3.2 の空配列は set -u で落ちるので文字列で持つ)。
# keep_error は keep_load が 1 を返した理由で、missing (無い・読めない) か bad (読めない行が在る)。呼び側は通知の印を
# 分ける (同じ日に、無い → 作った → 書き間違い、でも 2 本目の知らせが出るように)。
keep_entries="" keep_loaded=0 keep_error=""
# 行が対象の中を指すとき (祖先の一致) も当てるか。worktree-gc は対象を消すと中身も消えるので当てる (1)。
# agent-gc はセッションを止めるだけで中身は消えないので、source した後で 0 にする。
keep_ancestors=1

# リストを読む。読めなければ 1。途中でファイルが消えても判定が変わらないよう、1 回の実行で 1 度だけ呼ぶ。
# 読めた回は行数を、読めない行がある回はその行番号を (中身は出さない) 呼び側の log に出す。
# 実体パスは /bin/pwd -P で取る。bash 組み込みの pwd -P は打った綴りのまま返すので、大文字小文字を区別しない
# ファイルシステム (macOS の既定) で綴りの違う行が、実在するディレクトリに当たらない。組み込みの形
# (symlink は解くが綴りは打ったまま) も持つ。持たないと、symlink を通り綴りの違う行が、まだ無い対象を守らない。
keep_load() {
    local l r n=0 bad="" np=0 nn=0 f
    keep_entries="" keep_loaded=0 keep_error=missing
    [ -f "$CLEANUP_KEEP" ] && [ -r "$CLEANUP_KEEP" ] || return 1
    # 末尾に改行の無い最後の行も読む (落とすと、その行が黙って守られなくなる)。
    while IFS= read -r l || [ -n "$l" ]; do
        n=$((n + 1))
        l=${l%$'\r'}
        # 1 行目の BOM はエディタが付けるもので画面に見えないので、落として読み進める。
        if [ "$n" = 1 ]; then l=${l#$'\xef\xbb\xbf'}; fi
        # 読み違えると、守ったつもりの行が黙って何も守らない。そういう行は名前の行にせず、リスト全体を読めないにする
        # (その回は何も消さず、通知が出る)。2 行目以降の BOM と行の途中の CR (CR だけの改行) は、行の形を変えてしまう。
        case "$l" in $'\xef\xbb\xbf'* | *$'\r'*) bad="${bad:+$bad, }$n"; continue ;; esac
        l=${l#"${l%%[![:space:]]*}"}
        l=${l%"${l##*[![:space:]]}"}
        case "$l" in
            '' | '#'*) continue ;;
            # シェルの変数や引用符は展開しない。行の途中の # はコメントにならない (パスにも名前にも入りうる文字なので、
            # 空白 + # は書き間違いとみなす)。
            '$'* | '"'* | "'"* | *[[:space:]]'#'*) bad="${bad:+$bad, }$n"; continue ;;
            \~) l=$HOME ;;
            \~/*) l=$HOME/${l#\~/} ;;
        esac
        case "$l" in
            /*)
                np=$((np + 1))
                # 末尾の / は区切りで比べるときに邪魔なので落とす (/ だけの行は空になり、全部のパスに当たる)。
                while [ "${l%/}" != "$l" ]; do l=${l%/}; done
                keep_entries+="p:$l"$'\n'
                # /tmp と /private/tmp のように、同じ場所を別の名前で書いても当たるよう実体パスでも持つ。
                # まだ無いパスは実体に直せないので、文字どおりの形だけで比べる。
                for f in /bin/pwd pwd; do
                    r=$(cd "${l:-/}" 2>/dev/null && "$f" -P) || r=""
                    while [ "${r%/}" != "$r" ]; do r=${r%/}; done
                    # 3 つの形のうち同じものは 1 つにする。
                    case $'\n'"$keep_entries" in *$'\n'"p:$r"$'\n'*) continue ;; esac
                    if [ -n "$r" ]; then keep_entries+="p:$r"$'\n'; fi
                done
                ;;
            # 名前 (compose project) に / と \ は入らず、~ でも始まらない。$HOME/… の書き間違い、~user、
            # Windows の形のパスもここに来る。
            */* | *\\* | \~*) bad="${bad:+$bad, }$n" ;;
            *) nn=$((nn + 1)); keep_entries+="n:$l"$'\n' ;;
        esac
    done <"$CLEANUP_KEEP" || return 1
    if [ -n "$bad" ]; then
        keep_entries="" keep_error=bad
        log "WARN: 「触らない」リスト $CLEANUP_KEEP の $bad 行目を読めない (パスは / か ~/ で始め、コメントは行頭の # だけ。\$HOME・引用符・\\・~ で始まる名前、行の途中の CR (CR だけの改行)、2 行目以降の BOM は使えない)"
        return 1
    fi
    keep_loaded=1 keep_error=""
    log "keep: パス $np 行・名前 $nn 行"
}

# 対象のどれか 1 つでもリストに当たれば 0。/ で始まる対象はパス、それ以外は名前として比べる。
# パスは区切りで比べる (/a/pr-12 の行は /a/pr-12 と /a/pr-12/x に当たり、/a/pr-123 には当たらない)。
# keep_ancestors=1 なら、行が対象の中を指すとき (/a/wt/data の行と /a/wt) も当てる。対象を消すと、守りたい中身も一緒に消えるため。
# 呼び側は `if keep_match …` で受ける (当たらないときの 1 で set -e が落ちないように)。
keep_match() {
    local t r e l x
    # keep_load を通っていなければ、何を守るか分からないので守る側に倒す。
    [ "$keep_loaded" = 1 ] || return 0
    for t in "$@"; do
        case "$t" in
            /*)
                r=$(cd "$t" 2>/dev/null && /bin/pwd -P) || r=$t
                while IFS= read -r e; do
                    case "$e" in p:*) l=${e#p:} ;; *) continue ;; esac
                    for x in "$t" "$r"; do
                        if [[ "$x" == "$l" || "$x" == "$l"/* ]]; then return 0; fi
                        if [ "$keep_ancestors" = 1 ] && [[ "$l" == "$x"/* ]]; then return 0; fi
                    done
                done <<<"$keep_entries"
                ;;
            ?*) if grep -qxF -- "n:$t" <<<"$keep_entries"; then return 0; fi ;;
        esac
    done
    return 1
}

# ---- 規則ごとのスイッチ ----
# 掃除ジョブは origin/main の写しで動くので、判定を足すとマージした次の回から本番で効く。マージと有効化を分けるため、
# 新しい規則は設定 (worktree-gc なら ~/.config/worktree-gc.env) の RULE_<規則名>=off|list|on で動かす。
# off は動かさない、list は対象を一覧に出すだけ、on は実際に止める・消す。未設定と、3 つのどれでもない値は off
# (打ち間違いで消し始めない)。値は読み込み済みのシェル変数から取るので、設定ファイルの source は呼び側で済ませておく。
rule_mode() { # rule_mode <規則名>: off / list / on のどれかを標準出力に出す
    local v=""
    case "$1" in
        '' | *[!A-Za-z0-9_]*)
            log "WARN: 規則名 '$1' は使えない。off として扱う" >&2
            echo off
            return 0
            ;;
    esac
    v="RULE_$1"
    v=${!v:-}
    case "$v" in
        off | list | on) echo "$v" ;;
        '') echo off ;;
        # 標準出力は値なので、WARN は標準エラーに出す (launchd は両方を同じログに書く)。
        *) log "WARN: RULE_$1=$v は off / list / on のどれでもない。off として扱う" >&2; echo off ;;
    esac
}
