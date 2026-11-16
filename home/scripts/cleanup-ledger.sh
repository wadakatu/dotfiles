#!/usr/bin/env bash
#
# 掃除ジョブが止めた・消したものを 1 行ずつ残す台帳。各スクリプトが自分と同じディレクトリから source する。
#   . "$(dirname "${BASH_SOURCE[0]}")/cleanup-ledger.sh"
#   ledger_add <種類> <対象> <当たった規則> <戻し方のコマンド> <戻らないもの>
#
# ログは毎時の「残した理由」に埋もれ、ブランチやセッションも残らない。後から「何が消えたか」「どう戻すか」を
# 引けるよう、消したものだけを別のファイルに残す。直近は zsh の別名 cleanup-ledger で表にして見る。
#
# 台帳はタブ区切り・追記のみ。列は 時刻 (ISO 8601、ローカル時刻) / 種類 / 対象 / 当たった規則 / 戻し方 / 戻らないもの。
# 列は後ろに足すだけにする (並べ替えない、途中に挟まない)。worktree-gc は origin/main の写しを、agent-gc は
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
