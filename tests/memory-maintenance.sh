#!/usr/bin/env bash
# home/scripts/memory-maintenance.sh の判定を確かめる。CI (.github/workflows/nix.yml) と手元で回す。
#   bash tests/memory-maintenance.sh
# claude / gh / orca / osascript は偽物に置き換える。AI の実際の権限は試走で確かめる (docs/memory-maintenance-design.md 10 節)。
set -u
# shellcheck disable=SC2016,SC2329  # '...' の中の $x は偽コマンドや jq の変数。check に渡す関数は間接的に呼ぶ

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/home/scripts/memory-maintenance.sh"
base=$(mktemp -d)
trap '[ "${KEEP:-0}" = 1 ] && echo "残した: $base" || rm -rf "$base"' EXIT
fail=0
check() { # check <説明> <コマンド...>
    if ! "${@:2}" >/dev/null 2>&1; then echo "FAIL [$CASE] $1"; fail=1; fi
}

# ---- 偽のコマンド ----
mkdir -p "$base/bin"
cat >"$base/bin/claude" <<'EOF'
#!/usr/bin/env bash
# 最後の引数 (プロンプト) を記録し、$FAKE/claude.sh を作業領域で実行して $FAKE/result.json を返す
printf '%s\n' "${@: -1}" >>"$FAKE/claude-calls"
if [ -f "$FAKE/claude.sh" ]; then bash "$FAKE/claude.sh"; fi
if [ -f "$FAKE/claude-error" ]; then echo '{"is_error": true}'; exit 1; fi
jq -n --slurpfile r "$FAKE/result.json" '{is_error: false, total_cost_usd: 0.01, structured_output: $r[0]}'
EOF
cat >"$base/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/gh-calls"
case "$1 $2" in
    "api user") echo me ;;
    "repo view") case "$3" in me/*) echo PUBLIC ;; *) echo PRIVATE ;; esac ;;
    "pr create") echo "https://github.com/fake/pull/$(grep -c '^pr create' "$FAKE/gh-calls")" ;;
    "pr view") cat "$FAKE/pr-view" ;;
    "pr list") cat "$FAKE/pr-list" 2>/dev/null || true ;;
    api\ repos/*) echo '{"state": "closed", "title": "t", "closed_at": "2026-01-01T00:00:00Z"}' ;;
esac
EOF
cat >"$base/bin/orca" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo list") jq -n --arg a "$FAKE_APP" --arg d "$FAKE_DOT" '{result: {repos: [{path: $a}, {path: $d}]}}' ;;
    "worktree create")
        shift 2
        while [ $# -gt 0 ]; do case "$1" in --repo) repo=${2#path:}; shift ;; --branch) br=$2; shift ;; esac; shift; done
        wt="$FAKE/wt/$(printf '%s' "$br" | tr / -)"
        git -C "$repo" worktree add -q -b "$br" "$wt" origin/main >/dev/null 2>&1 || exit 1
        jq -n --arg p "$wt" '{result: {worktree: {path: $p}}}' ;;
    *) exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${@: -1}" >>"$FAKE/notify"\n' >"$base/bin/osascript"
chmod +x "$base/bin/"*

# ---- 環境 ----
make_repo() { # make_repo <slug> <clone> <file> <content>: github.com/<slug>.git (bare) とクローンを作る
    git init -q --bare "$T/github.com/$1.git"
    git clone -q "$T/github.com/$1.git" "$2" 2>/dev/null
    mkdir -p "$2/$(dirname "$3")"
    printf '%s\n' "$4" >"$2/$3"
    git -C "$2" add -A && git -C "$2" commit -q -m init && git -C "$2" push -q origin HEAD:main
    git -C "$2" remote set-head origin main
}
mem() { # mem <file> <type> <name> [本文]
    printf -- '---\nname: %s\ndescription: %s の説明\nmetadata:\n  type: %s\n---\n\n%s\n' "$3" "$3" "$2" "${4:-本文}" >"$M/$1"
}
idx() { printf -- '- [%s](%s) — %s\n' "$2" "$1" "$3" >>"$M/MEMORY.md"; }
commit_mem() { git -C "$M" add -A && git -C "$M" commit -q -m "snapshot test"; }
mark_onboarded() { git -C "$M" rev-parse HEAD >"$T/state/cursor/$P"; date +%s >"$T/state/full-done/$P"; }
setup() { # setup <名前>: オンボード済みの memory dir (alpha / fb / old) とリポ 2 つ
    CASE=$1
    T="$base/$1"
    mkdir -p "$T/fake" "$T/projects" "$T/state/cursor" "$T/state/full-done" "$T/cache" "$T/claude-home/rules" "$T/www"
    export FAKE="$T/fake" FAKE_APP="$T/www/app" FAKE_DOT="$T/www/dotfiles" GIT_CONFIG_GLOBAL="$T/gitconfig"
    git config -f "$GIT_CONFIG_GLOBAL" user.name t
    git config -f "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
    git config -f "$GIT_CONFIG_GLOBAL" init.defaultBranch main
    git config -f "$GIT_CONFIG_GLOBAL" url."$T/github.com/".insteadOf https://github.com/
    make_repo team/app "$FAKE_APP" AGENTS.md "# app"
    make_repo me/dotfiles "$FAKE_DOT" agents/claude/CLAUDE.md "# global"
    export P
    P=$(printf '%s' "$FAKE_APP" | sed 's/[^A-Za-z0-9]/-/g')
    export M="$T/projects/$P/memory"
    mkdir -p "$M"
    printf '# Memory Index\n\n注意: 索引の自由文は残る\n' >"$M/MEMORY.md"
    mem alpha.md project alpha "alpha 本文"
    mem fb.md feedback fb "ユーザーの判断。Why: 理由"
    mem old.md project old "古い前提"
    idx alpha.md "Alpha の見出し" "長い説明"
    idx fb.md FB feedback
    idx old.md Old 古い
    git -C "$M" init -q && commit_mem
    mark_onboarded
    printf '{"changes": [], "proposals": [], "needs_human": []}\n' >"$FAKE/result.json"
}
run_mm() { # run_mm [VAR=値...] [-- 引数...]
    local envs=() args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    args=("$@")
    env PATH="$base/bin:$PATH" PROJECTS_DIR="$T/projects" SHARED_DIR="$T/shared" CLAUDE_HOME="$T/claude-home" \
        DOTFILES_DIR="$FAKE_DOT" STATE_DIR="$T/state" CACHE_DIR="$T/cache" EXCLUDE_DIRS_RE="-scratch$" ${envs[@]+"${envs[@]}"} \
        "${MM_BASH:-bash}" "$script" ${args[@]+"${args[@]}"} >>"$T/log" 2>&1
}
result() { cat >"$FAKE/result.json"; }
cursor_is() { [ "$(cat "$T/state/cursor/$P")" = "$1" ]; }
prop_status() { jq -r --arg n "$1" 'select(.source_name == $n) | .status' "$T/state/proposals/"*.json; }

# 1. 対象なし → claude を呼ばない
setup no-change
mkdir -p "$T/projects/-private-tmp-scratch/memory"
printf -- '---\nname: a\ndescription: a\nmetadata:\n  type: project\n---\n' >"$T/projects/-private-tmp-scratch/memory/a.md"
run_mm
check "対象が無ければ claude を呼ばない" test ! -f "$FAKE/claude-calls"
check "一時ディレクトリの memory は扱わない" test ! -e "$T/projects/-private-tmp-scratch/memory/.git"
check "共有メモリが作られる" test -f "$T/shared/MEMORY.md"

# 2, 3. 変更を写す・索引は行単位・cursor = S1
setup apply
printf '追記\n' >>"$M/alpha.md"
printf '追記\n' >>"$M/old.md"
cat >"$FAKE/claude.sh" <<'EOF'
sed -i.bak 's/alpha の説明/短い説明/' "mem/$P/alpha.md" && rm "mem/$P/alpha.md.bak"
printf -- '---\nname: new\ndescription: 新しい\nmetadata:\n  type: project\n---\n\nnew\n' >"mem/$P/new.md"
EOF
result <<EOF
{"changes": [
  {"dir": "$P", "file": "alpha.md", "action": "update", "index_line": "- [Alpha の見出し](alpha.md) — 短い説明", "evidence": "短縮"},
  {"dir": "$P", "file": "new.md", "action": "create", "evidence": "新規"},
  {"dir": "$P", "file": "old.md", "action": "delete", "evidence": "前提が消えた"}],
 "proposals": [], "needs_human": []}
EOF
run_mm
check "対象ファイルがプロンプトに入る" grep -q "mem/$P/old.md" "$FAKE/claude-calls"
check "編集が live に写る" grep -q 短い説明 "$M/alpha.md"
check "新規ファイルが写る" test -f "$M/new.md"
check "削除が行われる" test ! -f "$M/old.md"
check "索引の自由文が残る" grep -qx '注意: 索引の自由文は残る' "$M/MEMORY.md"
check "index_line で行が置き換わる" grep -qxF -- '- [Alpha の見出し](alpha.md) — 短い説明' "$M/MEMORY.md"
check "触らない行は残る" grep -qxF -- '- [FB](fb.md) — feedback' "$M/MEMORY.md"
check "消したファイルの行が消える" bash -c "! grep -qF '(old.md)' '$M/MEMORY.md'"
check "新規ファイルの行が足される" grep -qF '(new.md)' "$M/MEMORY.md"
check "maintenance コミットができる" bash -c "git -C '$M' log -1 --format=%s | grep -q '^maintenance: daily'"
check "cursor は AI に渡した S1" cursor_is "$(git -C "$M" rev-parse HEAD~1)"
check "成功したら作業領域を消す" bash -c "! ls -d '$T'/cache/runs/*/daily"

# 4. feedback のガード
setup feedback
mem fb2.md feedback fb2 "長い本文 長い本文 長い本文 長い本文 長い本文"
mem fb3.md feedback fb3 "fb3 の本文"
idx fb2.md FB2 feedback
idx fb3.md FB3 feedback
printf 'x\n' >>"$M/fb.md"
cat >"$FAKE/claude.sh" <<'EOF'
printf -- '---\nname: fb2\ndescription: d\nmetadata:\n  type: feedback\n---\n\n' >"mem/$P/fb2.md"
printf 'fb3 の Why をここに統合した\n' >>"mem/$P/alpha.md"
EOF
result <<EOF
{"changes": [
  {"dir": "$P", "file": "fb.md", "action": "delete", "evidence": "古い"},
  {"dir": "$P", "file": "fb2.md", "action": "update", "evidence": "短縮"},
  {"dir": "$P", "file": "alpha.md", "action": "update", "evidence": "統合先"},
  {"dir": "$P", "file": "fb3.md", "action": "merge", "into": "alpha.md", "evidence": "重複"}],
 "proposals": [], "needs_human": []}
EOF
run_mm
check "feedback は単独で消さない" test -f "$M/fb.md"
check "feedback の本文を半分未満にしない" grep -q 長い本文 "$M/fb2.md"
check "name を残して本文が増えた統合は通る" test ! -f "$M/fb3.md"
check "見送りを通知する" grep -q 見送った "$FAKE/notify"

# 5. 並行書き込み: 保守の間に live が変わったファイルは上書きせず、翌日の対象に残す
setup concurrent
printf '追記\n' >>"$M/alpha.md"
cat >"$FAKE/claude.sh" <<'EOF'
printf 'AI の編集\n' >>"mem/$P/alpha.md"
printf '対話セッションの追記\n' >>"$M/alpha.md"
printf -- '- [Late](late.md) — 保守中に足された行\n' >>"$M/MEMORY.md"
EOF
result <<EOF
{"changes": [{"dir": "$P", "file": "alpha.md", "action": "update", "index_line": "- [Alpha の見出し](alpha.md) — 変更", "evidence": "x"}],
 "proposals": [], "needs_human": []}
EOF
run_mm
check "対話セッションの書き込みが残る" grep -q 対話セッションの追記 "$M/alpha.md"
check "AI の編集で上書きしない" bash -c "! grep -q 'AI の編集' '$M/alpha.md'"
check "保守中に足された索引の行が残る" grep -qF '(late.md)' "$M/MEMORY.md"
check "写さなかったファイルの索引は変えない" grep -qxF -- '- [Alpha の見出し](alpha.md) — 長い説明' "$M/MEMORY.md"
rm "$FAKE/claude.sh"
printf '{"changes": [], "proposals": [], "needs_human": []}\n' >"$FAKE/result.json"
run_mm
check "見送ったファイルが翌日の対象に入る" test "$(grep -c "mem/$P/alpha.md" "$FAKE/claude-calls")" -ge 2

# 6. 共有への移動: 共有側が確定してから元を消す
setup move
mem tip.md project tool-tip "gh の使い方"
idx tip.md Tip tip
mem tip2.md project tool-tip2 "zsh の使い方"
idx tip2.md Tip2 tip
printf 'x\n' >>"$M/tip.md"
printf 'x\n' >>"$M/tip2.md"
cat >"$FAKE/claude.sh" <<'EOF'
printf -- '---\nname: tool-tip\ndescription: gh\nmetadata:\n  type: reference\n---\n\ngh の使い方\n' >mem/shared/tip.md
EOF
result <<EOF
{"changes": [
  {"dir": "shared", "file": "tip.md", "action": "create", "evidence": "共有へ"},
  {"dir": "$P", "file": "tip.md", "action": "move", "into": "shared/tip.md", "evidence": "リポに依存しない"},
  {"dir": "$P", "file": "tip2.md", "action": "move", "into": "shared/tip2.md", "evidence": "共有側を作り忘れた"}],
 "proposals": [], "needs_human": []}
EOF
run_mm
check "共有にコミットされる" git -C "$T/shared" ls-files --error-unmatch tip.md
check "共有の索引に行が足される" grep -qF '(tip.md)' "$T/shared/MEMORY.md"
check "移した元が消える" test ! -f "$M/tip.md"
check "共有側が無ければ元を消さない" test -f "$M/tip2.md"

# 7. 検証に失敗したら何も適用しない
setup invalid
printf '追記\n' >>"$M/alpha.md"
before=$(cat "$T/state/cursor/$P")
printf 'printf "申告していない\\n" >>"mem/$P/old.md"\n' >"$FAKE/claude.sh"
result <<EOF
{"changes": [{"dir": "$P", "file": "alpha.md", "action": "update", "evidence": "x"}], "proposals": [], "needs_human": []}
EOF
run_mm
check "申告外の diff があれば写さない" bash -c "! grep -q 申告していない '$M/old.md'"
check "cursor を進めない" cursor_is "$before"
check "作業領域を残す" bash -c "ls -d '$T'/cache/runs/*/daily/work"
check "通知する" grep -q 適用しなかった "$FAKE/notify"
rm "$FAKE/claude.sh"
touch "$FAKE/claude-error"
run_mm
check "is_error でも cursor を進めない" cursor_is "$before"

# 8. 昇格の提案と PR
setup promote
printf '追記\n' >>"$M/alpha.md"
prop() { # prop <name> <repo> <path> <content> [confidence]
    jq -nc --arg p "$P" --arg n "$1" --arg r "$2" --arg t "$3" --arg c "$4" --arg conf "${5:-高}" \
        '{source_dir: $p, source_file: "alpha.md", source_name: $n, kind: "global", target_repo: $r, target_path: $t,
          new_content: $c, title: "Add a rule", body: "出典: alpha", commit_message: "Add a rule",
          after_merge: {delete: true}, confidence: $conf, public_safe: true}'
}
{
    printf '{"changes": [], "needs_human": [], "proposals": ['
    prop alpha "$FAKE_DOT" agents/claude/rules/git.md $'# git\n\n- rebase の前に fetch する\n'; printf ','
    prop beta "$FAKE_DOT" agents/claude/rules/leak.md $'- 詳細は #1234 を見る\n'; printf ','
    prop delta "$FAKE_DOT" home/zsh.nix 'x'; printf ','
    prop gamma "$FAKE_APP" .claude/rules/app.md $'- app の規則\n' 中
    printf ']}\n'
} >"$FAKE/result.json"
run_mm MAX_PR_PER_DAY=1
check "許可リスト外の target_path は捨てる" test "$(ls "$T/state/proposals" | wc -l | tr -d ' ')" = 3
check "公開前検査に当たれば保留" test "$(prop_status beta)" = held
check "1 日の上限まで PR にする (dotfiles から)" test "$(prop_status alpha)" = open
check "上限を超えた分は残す" test "$(prop_status gamma)" = pending
check "ブランチが push される" git -C "$T/github.com/me/dotfiles.git" rev-parse --verify chore/memory-alpha
run_mm MAX_PR_PER_DAY=1
check "上限は同じ日の 2 回目の実行にも効く" test "$(prop_status gamma)" = pending
run_mm MAX_PR_PER_DAY=5
check "上限が空けばチームのリポも PR にする" test "$(prop_status gamma)" = open
check "PR は 2 件だけ" test "$(grep -c '^pr create' "$FAKE/gh-calls")" = 2

setup stale
printf '追記\n' >>"$M/alpha.md"
{ printf '{"changes": [], "needs_human": [], "proposals": ['; prop alpha "$FAKE_DOT" agents/claude/rules/git.md $'- 規則\n'; printf ']}\n'; } >"$FAKE/result.json"
run_mm MAX_PR_PER_DAY=0
mkdir -p "$FAKE_DOT/agents/claude/rules"
printf -- '- 別の変更\n' >"$FAKE_DOT/agents/claude/rules/git.md"
git -C "$FAKE_DOT" add -A && git -C "$FAKE_DOT" commit -q -m other && git -C "$FAKE_DOT" push -q origin HEAD:main
run_mm MAX_PR_PER_DAY=5
check "提案のあとに昇格先が変わったら stale" test "$(prop_status alpha)" = stale

setup recover
printf '{"changes": [], "proposals": [], "needs_human": []}\n' >"$FAKE/result.json"
mkdir -p "$T/state/proposals"
jq -n --arg r "$FAKE_DOT" '{id: "r1", status: "creating", source_name: "x", target_repo: $r, target_path: "agents/claude/rules/x.md",
    slug: "me/dotfiles", branch: "chore/memory-x", confidence: "高", created_at: "2026-01-01"}' >"$T/state/proposals/r1.json"
echo "https://github.com/fake/pull/99" >"$FAKE/pr-list"
run_mm
check "creating で止まった提案を PR から復旧する" test "$(jq -r .pr_url "$T/state/proposals/r1.json")" = "https://github.com/fake/pull/99"

# 9. マージ後の後片付け
cleanup_case() { # cleanup_case <名前> <PR の状態>
    setup "$1"
    mem prom.md project prom "昇格する内容"
    mem link.md project link "関連: [[prom]]"
    idx prom.md Prom 昇格
    idx link.md Link 関連
    commit_mem && mark_onboarded
    mkdir -p "$FAKE_DOT/agents/claude/rules"
    printf -- '- 昇格した規則の行\n' >"$FAKE_DOT/agents/claude/rules/x.md"
    git -C "$FAKE_DOT" add -A && git -C "$FAKE_DOT" commit -q -m promote && git -C "$FAKE_DOT" push -q origin HEAD:main
    cp "$FAKE_DOT/agents/claude/rules/x.md" "$T/claude-home/rules/x.md"
    printf '%s\t%s\t2026-10-31T00:00:00Z\n' "$2" "$(git -C "$FAKE_DOT" rev-parse HEAD)" >"$FAKE/pr-view"
    mkdir -p "$T/state/proposals"
    jq -n --arg p "$P" --arg r "$FAKE_DOT" --arg b "$(git hash-object "$M/prom.md")" \
        '{id: "c1", status: "open", pr_url: "https://github.com/fake/pull/1", source_dir: $p, source_file: "prom.md", source_name: "prom",
          target_repo: $r, target_path: "agents/claude/rules/x.md", source_blob: $b, after_merge: {delete: true},
          slug: "me/dotfiles", visibility: "PUBLIC", confidence: "高"}' >"$T/state/proposals/c1.json"
}
cleanup_case cleanup MERGED
run_mm
check "マージされて見えたら元を消す" test ! -f "$M/prom.md"
check "[[name]] を書き換える" grep -qF 'prom（昇格済み → agents/claude/rules/x.md）' "$M/link.md"
check "索引の行を消す" bash -c "! grep -qF '(prom.md)' '$M/MEMORY.md'"
check "提案は done" test "$(prop_status prom)" = "done"
check "後片付けの変更をコミットする" test -z "$(git -C "$M" status --porcelain)"

cleanup_case cleanup-changed MERGED
printf '提案のあとの追記\n' >>"$M/prom.md"
run_mm
check "元が変わっていたら消さない" test -f "$M/prom.md"
check "削り直しに回す" test -f "$T/state/retrim/$P"

cleanup_case cleanup-invisible MERGED
rm "$T/claude-home/rules/x.md"
run_mm
check "live に見えなければ消さない" test -f "$M/prom.md"
check "マージ済みのまま待つ" test "$(prop_status prom)" = merged

cleanup_case cleanup-closed CLOSED
run_mm
check "閉じられた PR は rejected" test "$(prop_status prom)" = rejected
check "rejected なら元を消さない" test -f "$M/prom.md"

# 10. ロック
setup lock
printf '追記\n' >>"$M/alpha.md"
mkdir -p "$T/state/lock" && echo $$ >"$T/state/lock/pid"
run_mm
check "前の実行が動いていれば何もしない" test ! -f "$FAKE/claude-calls"

# 11. DRY_RUN と、全件の見直し (seed つき)
setup dry
mkdir -p "$T/projects/-other/memory"
printf -- '---\nname: a\ndescription: a\nmetadata:\n  type: project\n---\n' >"$T/projects/-other/memory/a.md"
printf '追記\n' >>"$M/alpha.md"
before=$(cat "$T/state/cursor/$P")
run_mm DRY_RUN=1
check "DRY_RUN は git を作らない" test ! -e "$T/projects/-other/memory/.git"
check "DRY_RUN は claude を呼ばない" test ! -f "$FAKE/claude-calls"
check "DRY_RUN は cursor を変えない" cursor_is "$before"

setup full
rm "$T/state/cursor/$P" "$T/state/full-done/$P"
mkdir -p "$T/state/seed" && printf '前回の分類\n' >"$T/state/seed/$P.md"
run_mm
check "オンボード前の dir を全件見直す" grep -q "mem/$P/fb.md" "$FAKE/claude-calls"
check "seed を渡す" grep -q seed.md "$FAKE/claude-calls"
check "全件の見直しで full-done ができる" test -f "$T/state/full-done/$P"
check "全件の見直しで cursor ができる" test -f "$T/state/cursor/$P"
check "使った seed を片付ける" test -f "$T/state/seed/$P.md.used"

[ "$fail" = 0 ] && echo "memory-maintenance: all checks passed"
if [ "$fail" != 0 ]; then echo "ログ: 各ケースの log を見るには trap を外して再実行する"; fi
exit "$fail"
