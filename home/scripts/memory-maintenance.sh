#!/usr/bin/env bash
#
# Claude Code の auto memory (~/.claude/projects/<p>/memory/) と共有メモリ (~/.claude-shared-memory/) を整理する。
#   1. 各 memory dir を git で snapshot する (保守の変更を git revert で戻せるように)
#   2. 前回以降に変わったファイルと lint の検出だけを、claude -p --restricted に整理させる
#      AI ができるのは作業領域の読み取りと、memory の写し (worktree) の編集だけ
#   3. AI の編集をガードに通して live に写す。削除・移動・索引の行の編集はスクリプトが行う
#   4. 昇格の提案を 1 件 1 PR で出す。公開リポは push の前に社内情報を検査する
#   5. マージされて昇格先に見えた提案の、元のメモリを縮小・削除する
#   6. 全件の見直しが 28 日以上前の dir を 1 つ選び、全件を見直す
# 設計は docs/memory-maintenance-design.md。launchd から毎日 04:30 に実行される (home/memory-maintenance.nix)。
#
# 手で確認するとき (何も書かず、AI も起動しない):
#   DRY_RUN=1 ~/www/personal/dotfiles/home/scripts/memory-maintenance.sh
# 1 つの dir を今すぐ全件見直す:
#   ~/www/personal/dotfiles/home/scripts/memory-maintenance.sh full <p> [--seed <file>]
#
set -euo pipefail
# shellcheck disable=SC2016  # '...' の中の $x は jq の変数 (シェルに展開させない)

# launchd の PATH には nix のパッケージ (jq, yq, gh, orca) も claude も入らない。呼び出し元の PATH は前に残す (テストの偽コマンド用)。
PATH="$PATH:/etc/profiles/per-user/${USER}/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export PATH
# launchd の環境にはロケールが無く、日本語がバイト単位で扱われる。
export LC_ALL=en_US.UTF-8

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
SHARED_DIR="${SHARED_DIR:-$HOME/.claude-shared-memory}"
# dotfiles に昇格した内容が実際に読まれる場所 (~/.claude/CLAUDE.md は手動コピー、rules と skills は symlink)。
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/www/personal/dotfiles}"
STATE_DIR="${STATE_DIR:-$HOME/Library/Application Support/memory-maintenance}"
# AI の作業領域。--allowedTools の Edit(//...) に入れるので、空白の無いパスにする。
CACHE_DIR="${CACHE_DIR:-$HOME/Library/Caches/memory-maintenance}"
PROMPT_FILE="${PROMPT_FILE:-$SCRIPT_DIR/memory-maintenance-prompt.md}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCRIPT_DIR/memory-maintenance-schema.json}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MODEL="${MODEL:-opus}"
DAILY_BUDGET_USD="${DAILY_BUDGET_USD:-5}"
# full は 1 回の実行全体の上限。各バッチには残額を渡す。
FULL_BUDGET_USD="${FULL_BUDGET_USD:-30}"
DAILY_TIMEOUT_SEC="${DAILY_TIMEOUT_SEC:-1800}"
FULL_TIMEOUT_SEC="${FULL_TIMEOUT_SEC:-3600}"
MAX_PR_PER_DAY="${MAX_PR_PER_DAY:-5}"
MAX_DELETE_DAILY="${MAX_DELETE_DAILY:-5}"
MAX_DELETE_FULL="${MAX_DELETE_FULL:-20}"
FULL_INTERVAL_DAYS="${FULL_INTERVAL_DAYS:-28}"
FULL_BATCH="${FULL_BATCH:-35}"
# MEMORY.md の読み込み上限は 200 行 / 25KB。手前で整理を始める。
INDEX_LINT_LINES="${INDEX_LINT_LINES:-180}"
INDEX_LINT_BYTES="${INDEX_LINT_BYTES:-22000}"
# 共有の索引は @import で毎セッション全文が載る (200 行 / 25KB の切り捨ての対象外)。
SHARED_INDEX_MAX_LINES="${SHARED_INDEX_MAX_LINES:-40}"
MAX_REFS="${MAX_REFS:-60}"
EXCLUDE_DIRS_RE="${EXCLUDE_DIRS_RE:-^-(private-)?(tmp|var-folders)-}"
# 最初の数回は保守のセッションを残し、transcript で何をしたか追えるようにする。定常運用では 0 にする。
KEEP_SESSIONS="${KEEP_SESSIONS:-1}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

TODAY=$(date +%F)
NOW=$(date +%s)
DOTFILES_P=""   # dotfiles の memory dir 名 (encode 済み)。main で決める

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
vlog() { if [ "$VERBOSE" = "1" ]; then log "$@"; fi; }
prefix() { awk -v p="$1" '{ print p "\t" $0 }'; }
# try <関数> [引数...]: set -e が効く subshell で実行し、終了コードを TRY_RC に置く。
# bash は `f || true` や `if f` の中で呼んだ関数の set -e を無視する (失敗しても先へ進んでしまう) ので、段ごとにこれで呼ぶ。
try() {
    set +e
    (set -e; "$@")
    TRY_RC=$?
    set -e
    if [ "$TRY_RC" != 0 ]; then log "WARN: $1 が失敗した (exit $TRY_RC)"; fi
}
notify() {
    log "通知: $*"
    [ "$DRY_RUN" = "1" ] && return 0
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "memory-maintenance"' -e 'end run' "$*" >/dev/null 2>&1 || true
}

# ---- memory dir と git ----

# memory dir には remote が無く、コミットは保守専用の名前で作る。
mg() { local d=$1; shift; git -C "$d" -c user.name=memory-maintenance -c user.email=memory-maintenance@localhost -c commit.gpgsign=false "$@"; }
encode() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
mem_path() { if [ "$1" = shared ]; then printf '%s' "$SHARED_DIR"; else printf '%s' "$PROJECTS_DIR/$1/memory"; fi; }
topic_files() { { ls -1 "$1" 2>/dev/null || true; } | { grep -E '^[^/]+\.md$' || true; } | { grep -vx 'MEMORY.md' || true; }; }
link_targets() { sed -n 's/.*](\([^)/]*\.md\)).*/\1/p'; }
fm() { yq --front-matter=extract "$1" "$2" 2>/dev/null || true; }
fm_type() { fm '.metadata.type // .type // ""' "$1"; }
fm_name() { fm '.name // ""' "$1"; }
body_bytes() { awk 'NR == 1 && /^---[[:space:]]*$/ { f = 1; next } f && /^---[[:space:]]*$/ { f = 0; next } !f' "$1" | wc -c | tr -d ' '; }
blob_at() { mg "$1" rev-parse -q --verify "$2:$3" 2>/dev/null || echo none; }
blob_now() { if [ -f "$1/$2" ]; then git hash-object "$1/$2"; else echo none; fi; }
onboarded() { [ "$1" = shared ] || [ -f "$STATE_DIR/cursor/$1" ]; }

discover_dirs() {
    local d p
    for d in "$PROJECTS_DIR"/*/memory; do
        [ -d "$d" ] || continue
        p=$(basename "$(dirname "$d")")
        # 一時ディレクトリ (サブエージェントの scratchpad など) で起動したセッションの memory は使い捨てなので扱わない
        if printf '%s' "$p" | grep -qE -e "$EXCLUDE_DIRS_RE"; then continue; fi
        if [ -n "$(topic_files "$d")" ]; then printf '%s\n' "$p"; fi
    done
    # 共有はまだ topic ファイルが無くても scope に入れる (他の dir から移す先になる)
    if [ -d "$SHARED_DIR" ]; then printf 'shared\n'; fi
}

snapshot() { # snapshot <dir> → HEAD
    local d=$1
    [ -e "$d/.git" ] || mg "$d" init -q -b main
    mg "$d" worktree prune
    mg "$d" add -A
    mg "$d" diff --cached --quiet || mg "$d" commit -q -m "snapshot $(date '+%F %T')"
    mg "$d" rev-parse -q --verify HEAD >/dev/null || mg "$d" commit -q --allow-empty -m "snapshot $(date '+%F %T')"
    mg "$d" rev-parse HEAD
}

# ---- リポの対応表と export ----

slug_of() { git -C "$1" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##' || true; }
default_ref() { git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main; }
repo_for() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$PMETA/repos.tsv"; }

# Claude Code は memory dir の名前を git リポのパスから作る (memory「Storage location」)。
# Orca に登録されたリポと dotfiles のパスを同じ規則で符号化して突き合わせる。
ORCA_OK=0
build_repo_map() {
    local paths r
    if paths=$(orca repo list --json 2>/dev/null | jq -er '.result.repos[].path' 2>/dev/null); then
        ORCA_OK=1
        { printf '%s\n' "$paths"; printf '%s\n' "$DOTFILES_DIR"; } | sort -u | while IFS= read -r r; do
            if [ -e "$r/.git" ]; then printf '%s\t%s\n' "$(encode "$r")" "$r"; fi
        done >"$PMETA/repos.tsv"
        [ "$DRY_RUN" = "1" ] || cp "$PMETA/repos.tsv" "$STATE_DIR/repos.tsv"
    elif [ -f "$STATE_DIR/repos.tsv" ]; then
        log "Orca に届かない。前回の対応表を使う"
        cp "$STATE_DIR/repos.tsv" "$PMETA/repos.tsv"
    else
        printf '%s\t%s\n' "$(encode "$DOTFILES_DIR")" "$DOTFILES_DIR" >"$PMETA/repos.tsv"
    fi
}

fetch_once() {
    if ! grep -qxF -- "$1" "$PMETA/fetched" 2>/dev/null; then
        git -C "$1" fetch --quiet origin 2>/dev/null || log "WARN: fetch に失敗 $1 (手元の origin で続ける)"
        printf '%s\n' "$1" >>"$PMETA/fetched"
    fi
}

export_repo() { # export_repo <p> <repo>: origin の既定ブランチを $WORK/repos/<p> に展開する (追跡ファイルだけ。.env は入らない)
    local p=$1 repo=$2 ref commit
    if awk -F'\t' -v p="$p" '$1 == p { f = 1 } END { exit !f }' "$META/exports.tsv"; then return 0; fi
    fetch_once "$repo"
    ref=$(default_ref "$repo")
    if ! commit=$(git -C "$repo" rev-parse -q --verify "$ref^{commit}" 2>/dev/null); then
        log "WARN: $repo に $ref が無い。export しない"
        return 0
    fi
    mkdir -p "$WORK/repos/$p"
    git -C "$repo" archive --format=tar "$commit" | tar -x -C "$WORK/repos/$p"
    printf '%s\t%s\t%s\t%s\n' "$p" "$repo" "$ref" "$commit" >>"$META/exports.tsv"
}

# 対象ファイルに出る issue / PR の状態を $WORK/refs.json に書く。AI に gh を持たせないための事前取得。
collect_refs() {
    local names="$META/repo-names.tsv" raw="$META/refs.txt" p f r slug name n
    : >"$names"
    : >"$raw"
    while IFS=$'\t' read -r p r; do
        slug=$(slug_of "$r")
        [ -n "$slug" ] || continue
        printf '%s\t%s\n%s\t%s\n' "${slug#*/}" "$slug" "$(basename "$r")" "$slug" >>"$names"
    done <"$PMETA/repos.tsv"
    while IFS=$'\t' read -r p f; do
        f="$(mem_path "$p")/$f"
        [ -f "$f" ] || continue
        slug=""
        r=$(repo_for "$p")
        if [ -n "$r" ]; then slug=$(slug_of "$r"); fi
        { grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[0-9]+' "$f" || true; } |
            sed -E 's#github\.com/([^/]+/[^/]+)/(issues|pull)/([0-9]+)#\1 \3#' >>"$raw"
        { grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' "$f" || true; } | tr '#' ' ' >>"$raw"
        { grep -oE '[A-Za-z0-9_.-]+ #[0-9]+' "$f" || true; } | while read -r name n; do
            name=$(awk -F'\t' -v k="$name" '$1 == k { print $2; exit }' "$names")
            if [ -n "$name" ]; then printf '%s %s\n' "$name" "${n#\#}" >>"$raw"; fi
        done
        if [ -n "$slug" ]; then
            { grep -oE '(^|[^A-Za-z0-9_/#])#[0-9]+' "$f" || true; } | { grep -oE '[0-9]+' || true; } | sed "s|^|$slug |" >>"$raw"
        fi
    done <"$META/targets.tsv"
    sort -u "$raw" | head -n "$MAX_REFS" | while read -r slug n; do
        gh api "repos/$slug/issues/$n" 2>/dev/null |
            jq -c --arg ref "$slug#$n" '{ref: $ref, state, title, closed_at, merged_at: (.pull_request.merged_at // null), is_pr: (.pull_request != null)}' ||
            jq -nc --arg ref "$slug#$n" '{ref: $ref, error: "取得できなかった"}'
    done | jq -s . >"$WORK/refs.json"
}

# ---- 対象と lint ----

dir_targets() { # dir_targets <p> <cursor>: cursor 以降の snapshot で変わった topic ファイル
    local p=$1 cursor=$2 d f
    d=$(mem_path "$p")
    # cursor のコミットが無い (dir を作り直した等) ときは全件を対象にする
    if [ -n "$cursor" ] && ! mg "$d" cat-file -e "$cursor^{commit}" 2>/dev/null; then cursor=""; fi
    {
        if [ -n "$cursor" ]; then
            mg "$d" log --format= --name-only --invert-grep --grep='^maintenance:' "$cursor..HEAD" -- '*.md'
            # 対話セッションが索引の行だけを直したときも、その行が指すファイルを対象にする
            mg "$d" log -p --format= --invert-grep --grep='^maintenance:' "$cursor..HEAD" -- MEMORY.md | { grep -E '^\+[^+]' || true; } | link_targets
        else
            topic_files "$d"
        fi
        if [ -f "$STATE_DIR/notes/$p" ]; then cut -f1 "$STATE_DIR/notes/$p"; fi
    } | { grep -vx 'MEMORY.md' || true; } | { grep -v / || true; } | sort -u | while IFS= read -r f; do
        if [ -n "$f" ] && [ -f "$d/$f" ]; then printf '%s\n' "$f"; fi
    done
}

lint_dir() { # lint_dir <p>: "<file>\t<指摘>"。file が - のものは索引全体の指摘
    local p=$1 d f meta lines bytes limit
    d=$(mem_path "$p")
    for f in $(topic_files "$d"); do
        meta=$(fm '[.name // "", .description // "", .metadata.type // .type // ""] | @tsv' "$d/$f")
        case "$meta" in
            *$'\t'$'\t'* | $'\t'* | *$'\t') printf '%s\tfrontmatter の name / description / metadata.type が欠けている\n' "$f" ;;
            "") printf '%s\tfrontmatter が読めない\n' "$f" ;;
        esac
        if [ -f "$d/MEMORY.md" ] && ! grep -qF -- "]($f)" "$d/MEMORY.md"; then printf '%s\t索引に行が無い\n' "$f"; fi
    done
    [ -f "$d/MEMORY.md" ] || return 0
    link_targets <"$d/MEMORY.md" | while IFS= read -r f; do
        if [ ! -f "$d/$f" ]; then printf -- '-\t索引の行が無いファイルを指している: %s\n' "$f"; fi
    done
    lines=$(wc -l <"$d/MEMORY.md" | tr -d ' ')
    bytes=$(wc -c <"$d/MEMORY.md" | tr -d ' ')
    limit=$INDEX_LINT_LINES
    [ "$p" = shared ] && limit=$SHARED_INDEX_MAX_LINES
    if [ "$lines" -gt "$limit" ]; then printf -- '-\t索引が %s 行 (目安 %s 行)。統合・削除で件数を減らす\n' "$lines" "$limit"; fi
    if [ "$bytes" -gt "$INDEX_LINT_BYTES" ]; then printf -- '-\t索引が %s バイト (目安 %s)。長い説明を短くする\n' "$bytes" "$INDEX_LINT_BYTES"; fi
}

# ---- AI の実行 ----

start_ai_run() { # start_ai_run <label>: $WORK (AI の cwd) と $META (このスクリプトだけが使う) を作る
    AI_DIR="$RUN_DIR/$1"
    WORK="$AI_DIR/work"
    META="$AI_DIR/meta"
    mkdir -p "$WORK/mem" "$WORK/repos" "$META"
    : >"$META/s1.tsv"
    : >"$META/targets.tsv"
    : >"$META/lint.tsv"
    : >"$META/exports.tsv"
    : >"$META/skipped.tsv"
    printf '[]\n' >"$WORK/refs.json"
}

s1_of() { awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$META/s1.tsv"; }
scope() { cut -f1 "$META/s1.tsv"; }

prepare_work() { # 全 scope の worktree (S1 で detach) と、対象 dir のリポの export を置く
    local p r
    for p in $(scope); do
        mg "$(mem_path "$p")" worktree add -q --detach "$WORK/mem/$p" "$(s1_of "$p")"
    done
    for p in $(cut -f1 "$META/targets.tsv" | sort -u); do
        r=$(repo_for "$p")
        if [ -n "$r" ]; then export_repo "$p" "$r"; fi
    done
    # グローバル昇格の提案には dotfiles の現在の内容が要る
    export_repo "$DOTFILES_P" "$DOTFILES_DIR"
    collect_refs
}

render_prompt() { # render_prompt <mode> <note>
    local p r
    cat "$PROMPT_FILE"
    printf '\n## この回の入力\n\n- モード: %s\n- 作業ディレクトリ: %s\n' "$1" "$WORK"
    if [ -n "$2" ]; then printf -- '- %s\n' "$2"; fi
    printf '\n### memory dir\n\n| dir | 写し | リポの export | リポ (target_repo) |\n|---|---|---|---|\n'
    for p in $(scope); do
        r=$(repo_for "$p")
        if [ -d "$WORK/repos/$p" ]; then
            printf '| %s | mem/%s/ | repos/%s/ | %s |\n' "$p" "$p" "$p" "$r"
        else
            printf '| %s | mem/%s/ | なし | %s |\n' "$p" "$p" "${r:-なし}"
        fi
    done
    printf '\nグローバル昇格の対象 (dotfiles): repos/%s/ (target_repo は %s)\n' "$DOTFILES_P" "$DOTFILES_DIR"
    printf '\n### 対象ファイル\n\n'
    awk -F'\t' '{ printf "- mem/%s/%s\n", $1, $2 }' "$META/targets.tsv"
    if [ -s "$META/lint.tsv" ]; then
        printf '\n### lint の指摘\n\n'
        awk -F'\t' '{ printf "- mem/%s: %s %s\n", $1, ($2 == "-" ? "" : $2), $3 }' "$META/lint.tsv"
    fi
    for p in $(scope); do
        if [ -s "$STATE_DIR/notes/$p" ]; then
            printf '\n### 前回からの申し送り (mem/%s)\n\n' "$p"
            awk -F'\t' '{ printf "- %s: %s\n", $1, $3 }' "$STATE_DIR/notes/$p"
        fi
    done
    printf '\n### 既存の提案 (この組は提案しない)\n\n'
    proposals_all | jq -r '"- [\(.status)] \(.source_name) → \(.target_repo):\(.target_path)"'
}

run_claude() { # run_claude <budget> <timeout> <turns> <effort> <out>
    local args rc=0
    args=(-p --restricted --strict-mcp-config --disable-slash-commands
        --tools "Read,Grep,Glob,Edit,Write"
        --permission-mode dontAsk --permission-prompts none
        --allowedTools "Edit(/$WORK/mem/**)"
        --model "$MODEL" --effort "$4"
        --max-budget-usd "$1" --max-turns "$3"
        --output-format json --json-schema "$(cat "$SCHEMA_FILE")")
    [ "$KEEP_SESSIONS" = "1" ] || args+=(--no-session-persistence)
    # CLAUDE_CODE_DISABLE_AUTO_MEMORY: 保守のセッション自身が auto memory を書かないように。
    # perl の alarm で時間の上限を付ける (macOS に timeout コマンドが無い)。
    (cd "$WORK" && CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$2" \
        "$CLAUDE_BIN" "${args[@]}" "$(cat "$META/prompt.md")" </dev/null >"$5" 2>"$5.err") || rc=$?
    # 費用と permission_denials を後から見るため、失敗した回も残す
    mkdir -p "$STATE_DIR/runs"
    cp "$5" "$STATE_DIR/runs/$(basename "$RUN_DIR")-$(basename "$5")" 2>/dev/null || true
    [ "$rc" = 0 ] || return 1
    jq -e '.is_error == false and (.structured_output | type) == "object"' "$5" >/dev/null
}

validate_result() { # validate_result <result.json>: 1 つでも外れたら何も適用しない
    local res=$1 p st path line
    jq -e --argjson scope "$(scope | jq -R . | jq -s .)" '
        def s: type == "string";
        (.changes | type == "array") and (.proposals | type == "array") and (.needs_human | type == "array")
        and all(.changes[];
            (.dir | s) and ([.dir] | inside($scope)) and (.file | s) and (.file | test("^[^/]+\\.md$"))
            and .file != "MEMORY.md"
            and (.action | IN("update", "create", "delete", "merge", "move", "index-only"))
            and ((.evidence // "") | length > 0)
            and ((.index_line // "") | contains("\n") | not)
            and (if .action == "merge" then ((.into // "") | test("^[^/]+\\.md$")) and .into != .file
                 elif .action == "move" then ((.into // "") | test("^shared/[^/]+\\.md$")) and .dir != "shared"
                 else true end))' "$res" >/dev/null || { log "検証: AI の出力の形が合わない"; return 1; }
    for p in $(scope); do
        while IFS= read -r line; do
            st=${line:0:2}
            path=${line:3}
            case "$st" in " M" | "??") ;; *) log "検証: 想定外の変更 $p/$path ($st)"; return 1 ;; esac
            case "$path" in */* | MEMORY.md | *[!A-Za-z0-9._-]*) log "検証: 編集してはいけないファイル $p/$path"; return 1 ;; esac
            case "$path" in *.md) ;; *) log "検証: .md 以外の変更 $p/$path"; return 1 ;; esac
            jq -e --arg p "$p" --arg f "$path" 'any(.changes[]; .dir == $p and .file == $f and (.action == "update" or .action == "create"))' "$res" >/dev/null ||
                { log "検証: 申告の無い変更 $p/$path"; return 1; }
        done < <(git -C "$WORK/mem/$p" status --porcelain --untracked-files=all)
    done
}

# ---- 適用 ----

skip() { log "見送り $1: $2"; printf '%s\t%s\n' "$1" "$2" >>"$META/skipped.tsv"; }

# index_apply <MEMORY.md> <edits>: edits は "del|set|add<TAB>file<TAB>行"。該当しない行・見出し・並びには触れない。
index_apply() {
    awk -F'\t' 'NR == FNR { if (!($2 in op)) ord[++n] = $2; op[$2] = $1; txt[$2] = substr($0, length($1) + length($2) + 3); next }
        { for (f in op) if (index($0, "](" f ")")) { if (op[f] == "del") next; if (op[f] == "set") { print txt[f]; done[f] = 1; next } } print }
        END { for (i = 1; i <= n; i++) { f = ord[i]; if (op[f] == "add" || (op[f] == "set" && !done[f])) print txt[f] } }' "$2" "$1"
}

index_edit() { # index_edit <p> <deleted> <copied> <created>: 索引を行単位で直す。直したら 0
    local p=$1 deleted=$2 copied=$3 created=$4 live idx raw="$META/index-raw" edits="$META/index-edits" f line op c i before name desc
    live=$(mem_path "$p")
    idx="$live/MEMORY.md"
    : >"$raw"
    for f in $deleted; do printf 'del\t%s\t\n' "$f" >>"$raw"; done
    while IFS=$'\t' read -r f line; do
        printf "%s" "$deleted" | grep -qxF -- "$f" && continue
        if [ -z "$line" ]; then
            printf 'del\t%s\t\n' "$f" >>"$raw"
        else
            case "$line" in "- ["*"]($f)"*) printf 'set\t%s\t%s\n' "$f" "$line" >>"$raw" ;; *) skip "$p/$f" "index_line の形が違う" ;; esac
        fi
    done < <(jq -r --arg p "$p" --arg copied "$copied" '.changes[]
        | select(.dir == $p and .index_line != null)
        | select(.action == "index-only" or ((.action == "update" or .action == "create") and (.file as $f | $copied | split("\n") | index($f))))
        | [.file, .index_line] | @tsv' "$META/result.json")
    for f in $created; do
        if ! awk -F'\t' -v f="$f" '$2 == f { x = 1 } END { exit !x }' "$raw"; then
            name=$(fm_name "$live/$f")
            desc=$(fm '.description // ""' "$live/$f")
            printf 'add\t%s\t- [%s](%s) — %s\n' "$f" "${name:-${f%.md}}" "$f" "$desc" >>"$raw"
        fi
    done
    [ -s "$raw" ] || return 1
    [ -f "$idx" ] || printf '# Memory Index\n\n' >"$idx"
    # AI は S1 の索引を見て index_line を書いた。保守の間に対話セッションがその行を変えていたら、上書きせず見送る。
    mg "$live" show "$(s1_of "$p"):MEMORY.md" >"$META/index-s1" 2>/dev/null || : >"$META/index-s1"
    # ロックが無いので、読んでから書き戻すまでに対話セッションが索引を変えたら読み直す。
    # ponytail: 比較から mv までの一瞬の競合は残る。続くなら flock 相当の協調が要る
    for i in 1 2 3; do
        before=$(git hash-object "$idx")
        : >"$edits"
        while IFS=$'\t' read -r op f line; do
            if [ "$(grep -F -- "]($f)" "$idx" || true)" != "$(grep -F -- "]($f)" "$META/index-s1" || true)" ]; then
                skip "$p/$f" "索引の行が保守の間に変わった (翌日に回す)"
                continue
            fi
            c=$(grep -cF -- "]($f)" "$idx" || true)
            case "$op" in
                set | add)
                    if [ "$c" -gt 1 ]; then skip "$p/$f" "索引に同じファイルの行が $c 行ある"; continue; fi
                    if [ "$c" = 0 ]; then op="add"; else op="set"; fi ;;
            esac
            printf '%s\t%s\t%s\n' "$op" "$f" "$line" >>"$edits"
        done <"$raw"
        [ -s "$edits" ] || return 1
        index_apply "$idx" "$edits" >"$idx.mm-tmp"
        if [ "$(git hash-object "$idx")" = "$before" ]; then
            if cmp -s "$idx.mm-tmp" "$idx"; then rm -f "$idx.mm-tmp"; return 1; fi
            mv "$idx.mm-tmp" "$idx"
            return 0
        fi
    done
    rm -f "$idx.mm-tmp"
    skip "$p/MEMORY.md" "索引が書き換わり続けた"
    return 1
}

apply_dir() { # apply_dir <p> <mode>: worktree の編集と申告をガードに通して live に写し、触ったパスだけコミットする
    local p=$1 mode=$2 live wt s1 tmp="$META/tmp" line f sb cb ot nt ob nb action into name ty protected before cap ndel=0
    local copied="" created="" deleted="" touched="" summary
    live=$(mem_path "$p")
    wt="$WORK/mem/$p"
    s1=$(s1_of "$p")
    # S2: 保守の間に対話セッションが書いたものを snapshot として残す。cursor (= S1) より後なので翌日の対象になる。
    snapshot "$live" >/dev/null

    # 1. 編集・新規。live が S1 から変わっていたら写さない (上書きしない)
    while IFS= read -r line; do
        f=${line:3}
        sb=$(blob_at "$live" "$s1" "$f")
        cb=$(blob_now "$live" "$f")
        if [ "$sb" != "$cb" ]; then skip "$p/$f" "保守の間に live が変わった (翌日に回す)"; continue; fi
        if [ "$sb" != none ]; then
            mg "$live" show "$s1:$f" >"$tmp"
            ot=$(fm_type "$tmp")
            if [ "$ot" = feedback ] || [ -z "$ot" ]; then
                nt=$(fm_type "$wt/$f")
                ob=$(body_bytes "$tmp")
                nb=$(body_bytes "$wt/$f")
                if [ "$ot" = feedback ] && [ "$nt" != feedback ]; then skip "$p/$f" "feedback の型を変えようとした"; continue; fi
                if [ $((nb * 2)) -lt "$ob" ]; then skip "$p/$f" "feedback / 型不明の本文を半分未満にしようとした"; continue; fi
            fi
        else
            created="$created$f"$'\n'
        fi
        cp "$wt/$f" "$live/.mm-tmp" && mv "$live/.mm-tmp" "$live/$f"
        copied="$copied$f"$'\n'
    done < <(git -C "$wt" status --porcelain --untracked-files=all)

    # 2. 削除を伴う申告。条件を満たさないものは消さずに残す (重複が残る側に倒す)
    cap=$MAX_DELETE_DAILY
    [ "$mode" = full ] && cap=$MAX_DELETE_FULL
    while IFS=$'\t' read -r action f into; do
        sb=$(blob_at "$live" "$s1" "$f")
        cb=$(blob_now "$live" "$f")
        [ "$cb" != none ] || continue
        if [ "$sb" != "$cb" ]; then skip "$p/$f" "保守の間に live が変わった (翌日に回す)"; continue; fi
        ty=$(fm_type "$live/$f")
        name=$(fm_name "$live/$f")
        [ -n "$name" ] || name=${f%.md}
        protected=0
        if [ "$ty" = feedback ] || [ -z "$ty" ]; then protected=1; fi
        case "$action" in
            delete)
                if [ "$protected" = 1 ]; then skip "$p/$f" "feedback / 型不明は単独で消さない"; continue; fi ;;
            merge)
                if [ ! -f "$live/$into" ] || ! grep -qF -- "$name" "$live/$into"; then skip "$p/$f" "統合先 $into に元の name が無い"; continue; fi
                if [ "$protected" = 1 ]; then
                    before=0
                    if mg "$live" show "$s1:$into" >"$tmp" 2>/dev/null; then before=$(body_bytes "$tmp"); fi
                    if [ "$(body_bytes "$live/$into")" -le "$before" ]; then skip "$p/$f" "統合先 $into の本文が増えていない"; continue; fi
                fi ;;
            move)
                into=${into#shared/}
                if [ ! -f "$SHARED_DIR/$into" ] || ! mg "$SHARED_DIR" ls-files --error-unmatch -- "$into" >/dev/null 2>&1 ||
                    ! mg "$SHARED_DIR" diff --quiet HEAD -- "$into" || ! grep -qF -- "$name" "$SHARED_DIR/$into"; then
                    skip "$p/$f" "共有の $into が確定していない"
                    continue
                fi ;;
        esac
        if [ "$ndel" -ge "$cap" ]; then skip "$p/$f" "1 回の削除の上限 $cap に達した"; continue; fi
        mg "$live" rm -q -- "$f"
        ndel=$((ndel + 1))
        deleted="$deleted$f"$'\n'
    done < <(jq -r --arg p "$p" '.changes[] | select(.dir == $p and (.action == "delete" or .action == "merge" or .action == "move")) | [.action, .file, (.into // "")] | @tsv' "$META/result.json")

    # 3. 索引
    touched="$copied$deleted"
    if index_edit "$p" "$deleted" "$copied" "$created"; then touched="${touched}MEMORY.md"$'\n'; fi
    [ -n "$touched" ] || return 0

    # 4. 触ったパスだけをコミットする。処理中に対話セッションが書いた別ファイルは次の snapshot に入る
    # (消したファイルは git rm でステージ済み。add すると pathspec が無いと言われる)
    printf '%s' "$touched" | while IFS= read -r f; do
        if [ -n "$f" ] && [ -e "$live/$f" ]; then mg "$live" add -- "$f"; fi
    done
    summary=$(jq -r --arg p "$p" '.changes[] | select(.dir == $p) | "- \(.action) \(.file)\(if .into then " → \(.into)" else "" end): \(.evidence)"' "$META/result.json")
    mg "$live" commit -q -m "maintenance: $mode $TODAY" -m "$summary"
    log "適用 $p: 写した $(printf '%s' "$copied" | grep -c . || true) 件、消した $ndel 件"
    if [ "$(wc -l <"$live/MEMORY.md" | tr -d ' ')" -gt 200 ] || [ "$(wc -c <"$live/MEMORY.md" | tr -d ' ')" -gt 25000 ]; then
        notify "$p の MEMORY.md が読み込み上限 (200 行 / 25KB) を超えている"
    fi
}

apply_all() { # apply_all <mode> [full の dir]: 共有を先に適用・コミットしてから他の dir (移動の元を消すのは共有が確定してから)
    local mode=$1 full_p=${2:-} p
    for p in $( (scope | grep -x shared || true); (scope | grep -vx shared || true) ); do
        apply_dir "$p" "$mode"
        if [ "$mode" = daily ] || [ "$p" = "$full_p" ]; then
            mkdir -p "$STATE_DIR/cursor"
            s1_of "$p" >"$STATE_DIR/cursor/$p"
            finish_notes "$p"
        fi
    done
    if [ -n "$full_p" ]; then
        mkdir -p "$STATE_DIR/full-done"
        printf '%s\n' "$NOW" >"$STATE_DIR/full-done/$full_p"
    fi
    jq -r '.needs_human[] | "- \(.dir)/\(.file): \(.question)"' "$META/result.json" | while IFS= read -r line; do
        printf '%s %s\n' "$TODAY" "$line" >>"$STATE_DIR/needs-human.md"
    done
    if [ "$(jq '.needs_human | length' "$META/result.json")" -gt 0 ]; then
        notify "人の判断が要るメモリがある ($STATE_DIR/needs-human.md)"
    fi
    if [ -s "$META/skipped.tsv" ]; then
        notify "ガードで見送った処置が $(wc -l <"$META/skipped.tsv" | tr -d ' ') 件ある (ログを参照)"
    fi
}

finish_ai_run() { # 成功: worktree を外して作業領域を消す
    local p
    for p in $(scope); do mg "$(mem_path "$p")" worktree remove --force "$WORK/mem/$p" 2>/dev/null || true; done
    rm -rf "$AI_DIR"
}

fail_ai_run() { # 失敗: 何も進めず、作業領域を残す (7 日後に消える)
    notify "整理を適用しなかった ($1)。作業領域: $AI_DIR"
}

# ---- 提案 ----

proposals_all() { find "$STATE_DIR/proposals" -name '*.json' -exec cat {} + 2>/dev/null || true; }
prop_file() { printf '%s/proposals/%s.json' "$STATE_DIR" "$1"; }
prop_get() { jq -r "$2" "$(prop_file "$1")"; }
prop_set() { # prop_set <id> <jq filter> [jq の引数...]: tmp + mv で書く
    local f
    f=$(prop_file "$1")
    jq "${@:3}" "$2" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

repo_visibility() {
    local v
    v=$(awk -F'\t' -v s="$1" '$1 == s { print $2; exit }' "$PMETA/visibility.tsv" 2>/dev/null)
    if [ -z "$v" ]; then
        v=$(gh repo view "$1" --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)
        printf '%s\t%s\n' "$1" "$v" >>"$PMETA/visibility.tsv"
    fi
    printf '%s' "$v"
}

# 公開前検査の語。対応表のリポの owner (自分以外) と、非公開リポの名前 (短い一般語を避けて 6 文字以上)。
# 公開リポのスクリプトに社名を書かないよう、実行時に作る。
leak_terms() {
    local r slug
    [ -f "$PMETA/leak-terms" ] && return 0
    while IFS=$'\t' read -r _ r; do
        slug=$(slug_of "$r")
        [ -n "$slug" ] || continue
        if [ "${slug%%/*}" != "$ME" ]; then printf '%s\n' "${slug%%/*}"; fi
        if [ "$(repo_visibility "$slug")" != PUBLIC ] && [ "${#slug}" -gt 0 ] && [ "$(printf '%s' "${slug#*/}" | wc -c)" -ge 6 ]; then
            printf '%s\n' "${slug#*/}"
        fi
    done <"$PMETA/repos.tsv" | { grep -v '^$' || true; } | sort -u >"$PMETA/leak-terms"
}

leak_hits() { # leak_hits <file>: 当たった語を出す (空なら公開してよい)
    leak_terms
    {
        if [ -s "$PMETA/leak-terms" ]; then grep -oiF -f "$PMETA/leak-terms" "$1" || true; fi
        grep -oE '#[0-9]+' "$1" || true
        grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$1" || true
        { grep -oE 'https?://[^][:space:])>"`<]+' "$1" || true; } |
            { grep -vE "^https?://(code\.claude\.com|docs\.claude\.com|docs\.anthropic\.com|github\.com/$ME)(/|$)" || true; }
    } | sort -u
}

allowed_target() { # allowed_target <repo> <path>
    local re
    case "$2" in *..* | /*) return 1 ;; esac
    if [ "$1" = "$DOTFILES_DIR" ]; then
        re='^agents/claude/CLAUDE\.md$|^agents/claude/rules/[^/]+\.md$|^agents/(claude/)?skills/[^/]+/SKILL\.md$'
    else
        re='^AGENTS\.md$|^CLAUDE\.md$|^\.claude/rules/[^/]+\.md$'
    fi
    [[ "$2" =~ $re ]]
}

intake_proposals() { # AI の提案を検証して proposals/<id>.json に置く
    local n i prop name src_dir src_file repo path exp commit id f base src_blob slug vis status reason scan="$META/scan"
    n=$(jq '.proposals | length' "$META/result.json")
    i=0
    mkdir -p "$STATE_DIR/proposals"
    while [ "$i" -lt "$n" ]; do
        prop=$(jq -c ".proposals[$i]" "$META/result.json")
        i=$((i + 1))
        name=$(jq -r .source_name <<<"$prop")
        src_dir=$(jq -r .source_dir <<<"$prop")
        src_file=$(jq -r .source_file <<<"$prop")
        repo=$(jq -r .target_repo <<<"$prop")
        path=$(jq -r .target_path <<<"$prop")
        # 昇格元は今回 AI に渡した scope の topic ファイルに限る (MEMORY.md や他所のファイルをマージ後に消さないため)
        case "$src_file" in
            */* | MEMORY.md | *[!A-Za-z0-9._-]*) log "提案を捨てる ($name): 昇格元 $src_file が topic ファイルではない"; continue ;;
            *.md) ;;
            *) log "提案を捨てる ($name): 昇格元 $src_file が topic ファイルではない"; continue ;;
        esac
        if [ -z "$(s1_of "$src_dir")" ] || [ "$(blob_at "$(mem_path "$src_dir")" "$(s1_of "$src_dir")" "$src_file")" = none ]; then
            log "提案を捨てる ($name): 昇格元 $src_dir/$src_file が今回の scope に無い"
            continue
        fi
        exp=$(awk -F'\t' -v r="$repo" '$2 == r { print; exit }' "$META/exports.tsv")
        if [ -z "$exp" ]; then log "提案を捨てる ($name): $repo は今回 export していない"; continue; fi
        if ! allowed_target "$repo" "$path"; then log "提案を捨てる ($name): $path は許可リストに無い"; continue; fi
        if [ "$(jq '.new_content | utf8bytelength' <<<"$prop")" -gt 40000 ]; then log "提案を捨てる ($name): new_content が大きすぎる"; continue; fi
        # マージ後に元を空にしないよう、消すか、frontmatter から始まる残す内容のどちらかを必須にする
        if ! jq -e '.after_merge.delete == true or ((.after_merge.content // "") | startswith("---"))' <<<"$prop" >/dev/null; then
            log "提案を捨てる ($name): after_merge が delete: true でも残す内容でもない"
            continue
        fi
        id=$(printf '%s\t%s\t%s' "$name" "$repo" "$path" | git hash-object --stdin)
        f=$(prop_file "$id")
        if [ -e "$f" ]; then vlog "提案は既にある ($name → $path)"; continue; fi
        commit=$(printf '%s' "$exp" | cut -f4)
        base=$(git -C "$repo" rev-parse -q --verify "$commit:$path" 2>/dev/null || echo new)
        case "$path" in */SKILL.md | AGENTS.md | CLAUDE.md | agents/claude/CLAUDE.md)
            if [ "$base" = new ]; then log "提案を捨てる ($name): $path は既存のファイルにしか足せない"; continue; fi ;;
        esac
        src_blob=$(blob_at "$(mem_path "$src_dir")" "$(s1_of "$src_dir")" "$src_file")
        slug=$(slug_of "$repo")
        vis=$(repo_visibility "$slug")
        status=pending
        reason=""
        if [ "$vis" != PRIVATE ] && [ "$vis" != INTERNAL ]; then
            # 公開リポ (と、公開かどうか分からないリポ)。push した時点で公開なので、ここと push 前の 2 回検査する。
            { git -C "$repo" show "$commit:$path" 2>/dev/null || true; } >"$META/base-content"
            {
                diff "$META/base-content" <(jq -j .new_content <<<"$prop") | sed -n 's/^> //p' || true
                jq -r '.target_path, .title, .body, .commit_message' <<<"$prop"
            } >"$scan"
            if [ "$(jq -r .public_safe <<<"$prop")" != true ]; then
                status=held
                reason="AI が public_safe にしなかった"
            elif hits=$(leak_hits "$scan") && [ -n "$hits" ]; then
                status=held
                reason="公開前検査に当たった: $(printf '%s' "$hits" | tr '\n' ' ')"
            fi
        fi
        jq -n --argjson p "$prop" --arg id "$id" --arg status "$status" --arg reason "$reason" --arg created "$TODAY" \
            --arg base "$base" --arg src "$src_blob" --arg slug "$slug" --arg vis "$vis" \
            '$p + {id: $id, status: $status, held_reason: $reason, created_at: $created, base_blob: $base,
                   source_blob: $src, slug: $slug, visibility: $vis}' >"$f.tmp" && mv "$f.tmp" "$f"
        log "提案 [$status] $name → $(basename "$repo"):$path"
        if [ "$status" = held ]; then notify "昇格の提案を保留した ($name): ${reason}。$f を直すか消す"; fi
    done
}

expected_blob() { # PR に入れる内容の blob (末尾の改行を補ったもの)
    { jq -j .new_content "$(prop_file "$1")"; if [ -n "$(jq -j '.new_content[-1:]' "$(prop_file "$1")" | tr -d '\n')" ]; then echo; fi; } | git hash-object --stdin
}

pr_from_worktree() { # pr_from_worktree <id>: worktree に内容を書き、検査してから commit・push・PR
    local id=$1 wt path repo slug branch cur base changed hits url def body="$PMETA/pr-body" scan="$PMETA/pr-scan"
    wt=$(prop_get "$id" .worktree)
    path=$(prop_get "$id" .target_path)
    repo=$(prop_get "$id" .target_repo)
    slug=$(prop_get "$id" .slug)
    branch=$(prop_get "$id" .branch)
    cur=$(git -C "$wt" rev-parse -q --verify "HEAD:$path" 2>/dev/null || echo new)
    base=$(prop_get "$id" .base_blob)
    if [ "$cur" != "$(expected_blob "$id")" ]; then
        if [ "$cur" != "$base" ]; then
            # 昇格先が提案のあとに変わった。提案を取り下げ、元のメモリを翌日の AI に渡して今の内容で出し直させる。
            # worktree はまだ何も書いていないので消してよい
            note "$(prop_get "$id" .source_dir)" "$(prop_get "$id" .source_file)" "" \
                "$path への昇格の提案は、提案のあとに昇格先が変わったので取り下げた。必要なら今の内容で提案し直す"
            orca worktree rm --worktree "path:$wt" --json >/dev/null 2>&1 || log "WARN: worktree を消せない $wt"
            rm -f "$(prop_file "$id")"
            log "提案 $id: $path が提案のあとに変わった。取り下げて出し直させる"
            return 1
        fi
        mkdir -p "$(dirname "$wt/$path")"
        jq -j .new_content "$(prop_file "$id")" >"$wt/$path"
        if [ -n "$(tail -c1 "$wt/$path")" ]; then echo >>"$wt/$path"; fi
        changed=$(git -C "$wt" status --porcelain --untracked-files=all | cut -c4-)
        if [ "$changed" != "$path" ]; then
            prop_set "$id" '.status = "held" | .held_reason = "worktree に想定外の差分がある"'
            notify "昇格 PR を保留した ($id): worktree に想定外の差分がある ($wt)"
            return 1
        fi
        git -C "$wt" add -- "$path"
        git -C "$wt" commit -q -m "$(prop_get "$id" .commit_message)"
    fi
    if [ "$(prop_get "$id" .visibility)" != PRIVATE ] && [ "$(prop_get "$id" .visibility)" != INTERNAL ]; then
        def=$(default_ref "$repo")
        { git -C "$wt" diff "$def...HEAD" -- "$path" | { grep -E '^\+' || true; } | { grep -vE '^\+\+\+' || true; }
          prop_get "$id" '.target_path, .branch, .title, .body, .commit_message'; } >"$scan"
        hits=$(leak_hits "$scan")
        if [ -n "$hits" ]; then
            prop_set "$id" '.status = "held" | .held_reason = $r' --arg r "push 前の公開前検査に当たった: $(printf '%s' "$hits" | tr '\n' ' ')"
            notify "昇格 PR を push せずに保留した ($id)。公開前検査に当たった"
            return 1
        fi
    fi
    # launchd には ssh-agent が無いことがあるので、gh の認証で https に push する。
    git -C "$wt" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q "https://github.com/$slug.git" "HEAD:refs/heads/$branch"
    prop_get "$id" .body >"$body"
    def=$(default_ref "$repo")
    url=$(gh pr create -R "$slug" --head "$branch" --base "${def#origin/}" --title "$(prop_get "$id" .title)" --body-file "$body")
    prop_set "$id" '.status = "open" | .pr_url = $u | .pr_created_at = $t' --arg u "$url" --arg t "$TODAY"
    log "昇格 PR: $url"
}

create_pr() { # create_pr <id>: 副作用の前に状態を保存する (途中で止まっても dispatch が再開する)
    local id=$1 repo name out wt branch
    repo=$(prop_get "$id" .target_repo)
    name=$(prop_get "$id" .source_name)
    prop_set "$id" '.status = "creating"'
    # ブランチ名は push した時点で公開される。メモリの名前 (社内の語を含みうる) ではなく提案の ID から作る
    if ! out=$(orca worktree create --repo "path:$repo" --name "memory: $(prop_get "$id" .title)" --branch "chore/memory-${id:0:12}" --no-parent --json 2>/dev/null); then
        prop_set "$id" '.status = "pending"'
        log "Orca で worktree を作れない ($name)。次回に回す"
        return 1
    fi
    wt=$(jq -r '.result.worktree.path // .result.path // ((.result.worktree.id // .result.id // "") | split("::") | .[1]) // empty' <<<"$out")
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
        prop_set "$id" '.status = "pending"'
        log "Orca の応答に worktree のパスが無い ($name)。次回に回す"
        return 1
    fi
    branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
    prop_set "$id" '.worktree = $w | .branch = $b' --arg w "$wt" --arg b "$branch"
    pr_from_worktree "$id"
}

recover_creating() { # creating で止まった提案のうち、PR が既にあるものを open にする (新しい PR は作らない)
    local id slug branch url wt
    for id in $(proposals_all | jq -r 'select(.status == "creating") | .id'); do
        slug=$(prop_get "$id" .slug)
        branch=$(prop_get "$id" '.branch // ""')
        url=""
        if [ -n "$branch" ]; then
            url=$(gh pr list -R "$slug" --head "$branch" --state all --json url -q '.[0].url // ""' 2>/dev/null || true)
        fi
        if [ -n "$url" ]; then
            prop_set "$id" '.status = "open" | .pr_url = $u | .pr_created_at = (.pr_created_at // $t)' --arg u "$url" --arg t "$TODAY"
            continue
        fi
        wt=$(prop_get "$id" '.worktree // ""')
        if [ -z "$wt" ] || [ ! -d "$wt" ]; then prop_set "$id" '.status = "pending"'; fi
    done
}

dispatch() { # 1 日 MAX_PR_PER_DAY 件まで PR にする。途中で止まったものの再開が先、次に確信度 高 → 中 → 低、dotfiles → チームのリポの順
    local made slots id
    recover_creating
    made=$(proposals_all | jq -s --arg t "$TODAY" '[.[] | select((.pr_created_at // "") == $t)] | length')
    slots=$((MAX_PR_PER_DAY - made))
    for id in $(proposals_all | jq -rs --arg dot "$DOTFILES_DIR" '
            (map(select(.status == "creating")) | sort_by(.created_at)) +
            (map(select(.status == "pending"))
             | sort_by(({"高": 0, "中": 1, "低": 2}[.confidence] // 3), (if .target_repo == $dot then 0 else 1 end), .created_at))
            | .[].id'); do
        [ "$slots" -gt 0 ] || break
        if [ "$(prop_get "$id" .status)" = creating ]; then
            try pr_from_worktree "$id"
        else
            if [ "$ORCA_OK" != 1 ]; then log "Orca に届かない。昇格 PR は次回に回す"; break; fi
            try create_pr "$id"
        fi
        if [ "$TRY_RC" = 0 ]; then slots=$((slots - 1)); fi
    done
}

# ---- マージ後の後片付け ----

live_path() { # dotfiles の target_path が実際に読まれる場所
    case "$1" in
        agents/claude/CLAUDE.md) printf '%s/CLAUDE.md' "$CLAUDE_HOME" ;;
        agents/claude/rules/*) printf '%s/rules/%s' "$CLAUDE_HOME" "${1#agents/claude/rules/}" ;;
        agents/skills/* | agents/claude/skills/*) printf '%s/skills/%s' "$CLAUDE_HOME" "${1#agents/*skills/}" ;;
    esac
}

visible() { # visible <id>: マージが既定ブランチにあり、追加した行が今の既定ブランチにも残っている (revert されていない)。dotfiles なら live 側にも見える
    local id=$1 repo path mc marker lp def
    repo=$(prop_get "$id" .target_repo)
    path=$(prop_get "$id" .target_path)
    mc=$(prop_get "$id" .merge_commit)
    fetch_once "$repo"
    def=$(default_ref "$repo")
    git -C "$repo" merge-base --is-ancestor "$mc" "$def" 2>/dev/null || return 1
    marker=$(git -C "$repo" diff "$mc^1" "$mc" -- "$path" | { grep -E '^\+' || true; } | { grep -vE '^\+\+\+' || true; } | sed 's/^+//' |
        awk '{ if (length($0) > length(m)) m = $0 } END { print m }')
    [ -n "$marker" ] || return 1
    { git -C "$repo" show "$def:$path" 2>/dev/null || true; } | grep -qF -- "$marker" || return 1
    [ "$repo" = "$DOTFILES_DIR" ] || return 0
    lp=$(live_path "$path")
    [ -n "$lp" ] && grep -qF -- "$marker" "$lp"
}

apply_after_merge() { # 元のメモリを after_merge どおりに縮小・削除し、[[name]] を書き換える
    local id=$1 src_dir src_file name target url live now d f touched
    src_dir=$(prop_get "$id" .source_dir)
    src_file=$(prop_get "$id" .source_file)
    name=$(prop_get "$id" .source_name)
    target=$(prop_get "$id" .target_path)
    url=$(prop_get "$id" .pr_url)
    live=$(mem_path "$src_dir")
    snapshot "$live" >/dev/null
    now=$(blob_now "$live" "$src_file")
    if [ "$now" = none ]; then
        prop_set "$id" '.status = "done"'
        return 0
    fi
    if [ "$now" != "$(prop_get "$id" .source_blob)" ]; then
        # 提案のあとに追記された。after_merge は使わず、翌日の AI に削り直させる
        note "$src_dir" "$src_file" "$id" "$target に昇格済み ($url)。昇格先で扱われた部分だけ削る"
        prop_set "$id" '.status = "retrim"'
        return 0
    fi
    if [ "$(prop_get "$id" '.after_merge.delete // false')" = true ]; then
        mg "$live" rm -q -- "$src_file"
        printf 'del\t%s\t\n' "$src_file" >"$PMETA/index-edits"
        if [ -f "$live/MEMORY.md" ]; then
            index_apply "$live/MEMORY.md" "$PMETA/index-edits" >"$live/MEMORY.md.mm-tmp" && mv "$live/MEMORY.md.mm-tmp" "$live/MEMORY.md"
        fi
    elif [ "$(prop_get "$id" '.after_merge.content // "" | startswith("---")')" = true ]; then
        prop_get "$id" '.after_merge.content' >"$live/.mm-tmp" && mv "$live/.mm-tmp" "$live/$src_file"
    else
        # 受け入れ時に弾いているので通常は来ない。元を空にしないよう、何もせずに AI へ回す
        note "$src_dir" "$src_file" "$id" "$target に昇格済み ($url)。昇格先で扱われた部分だけ削る"
        prop_set "$id" '.status = "retrim"'
        return 0
    fi
    for d in "$live" "$SHARED_DIR"; do
        [ -d "$d" ] || continue
        [ "$d" = "$live" ] || snapshot "$d" >/dev/null
        touched=""
        for f in $(grep -lF -- "[[$name]]" "$d"/*.md 2>/dev/null || true); do
            NAME=$name TARGET=$target perl -pi -e 's/\[\[\Q$ENV{NAME}\E\]\]/$ENV{NAME}（昇格済み → $ENV{TARGET}）/g' "$f"
            touched="$touched $(basename "$f")"
        done
        if [ "$d" = "$live" ]; then touched="$touched $src_file MEMORY.md"; fi
        # 消したファイルは git rm でステージ済み。残っているファイルだけ add する
        for f in $touched; do
            if [ -e "$d/$f" ]; then mg "$d" add -- "$f"; fi
        done
        mg "$d" diff --cached --quiet || mg "$d" commit -q -m "maintenance: cleanup $TODAY" -m "昇格済み: $name → $target ($url)"
    done
    prop_set "$id" '.status = "done"'
    log "後片付け: $src_dir/$src_file ($url)"
}

# 翌日の AI への申し送り。notes/<p> に "<file>\t<提案 id>\t<内容>" で残し、そのファイルを対象に入れる。
note() { # note <p> <file> <提案 id> <内容>
    mkdir -p "$STATE_DIR/notes"
    printf '%s\t%s\t%s\n' "$2" "$3" "$4" >>"$STATE_DIR/notes/$1"
}

finish_notes() { # finish_notes <p>: AI がそのファイルに処置を申告し、見送られなかった申し送りだけ片付ける
    local p=$1 f id note_text n
    [ -f "$STATE_DIR/notes/$p" ] || return 0
    : >"$META/notes-keep"
    while IFS=$'\t' read -r f id note_text n; do
        n=${n:-0}
        if awk -F'\t' -v k="$p/$f" '$1 == k { x = 1 } END { exit !x }' "$META/skipped.tsv"; then
            # 保守の間に live が変わって見送った。AI のせいではないので回数は数えない
            printf '%s\t%s\t%s\t%s\n' "$f" "$id" "$note_text" "$n" >>"$META/notes-keep"
        elif jq -e --arg p "$p" --arg f "$f" 'any(.changes[]; .dir == $p and .file == $f)' "$META/result.json" >/dev/null; then
            if [ -n "$id" ] && [ -f "$(prop_file "$id")" ] && [ "$(prop_get "$id" .status)" = retrim ]; then prop_set "$id" '.status = "done"'; fi
        elif [ $((n + 1)) -ge 3 ]; then
            printf '%s - %s/%s: 申し送りを 3 回渡しても処置されなかった (%s)\n' "$TODAY" "$p" "$f" "$note_text" >>"$STATE_DIR/needs-human.md"
            notify "申し送りを 3 回渡しても処置されなかった: $p/$f"
        else
            printf '%s\t%s\t%s\t%s\n' "$f" "$id" "$note_text" "$((n + 1))" >>"$META/notes-keep"
        fi
    done <"$STATE_DIR/notes/$p"
    if [ -s "$META/notes-keep" ]; then mv "$META/notes-keep" "$STATE_DIR/notes/$p"; else rm -f "$STATE_DIR/notes/$p"; fi
}

cleanup() {
    local id url st mc age
    for id in $(proposals_all | jq -r 'select(.status == "open" or .status == "merged") | .id'); do
        if [ "$(prop_get "$id" .status)" = open ]; then
            url=$(prop_get "$id" .pr_url)
            st=$(gh pr view "$url" --json state,mergeCommit,mergedAt -q '[.state, (.mergeCommit.oid // ""), (.mergedAt // "")] | @tsv' 2>/dev/null) || continue
            IFS=$'\t' read -r st mc _ <<<"$st"
            case "$st" in
                CLOSED) prop_set "$id" '.status = "rejected"'; log "却下: $url"; continue ;;
                MERGED) prop_set "$id" '.status = "merged" | .merge_commit = $m | .merged_epoch = $e' --arg m "$mc" --argjson e "$NOW" ;;
                *) continue ;;
            esac
        fi
        if visible "$id"; then
            apply_after_merge "$id"
        else
            age=$(( (NOW - $(prop_get "$id" '.merged_epoch // 0')) / 86400 ))
            if [ "$age" -ge 14 ] && [ "$(prop_get "$id" '.notified_invisible // false')" != true ]; then
                notify "マージから $age 日たっても昇格先に見えない: $(prop_get "$id" .pr_url)"
                prop_set "$id" '.notified_invisible = true'
            fi
        fi
    done
}

# ---- 日次と全件 ----

run_daily() {
    local p d cursor
    start_ai_run daily
    for p in $(discover_dirs); do
        d=$(mem_path "$p")
        printf '%s\t%s\n' "$p" "$(snapshot "$d")" >>"$META/s1.tsv"
        onboarded "$p" || continue
        cursor=$(cat "$STATE_DIR/cursor/$p" 2>/dev/null || true)
        dir_targets "$p" "$cursor" | prefix "$p" >>"$META/targets.tsv"
        lint_dir "$p" | prefix "$p" >>"$META/lint.tsv"
    done
    # lint で名指しされたファイルも対象に入れる
    awk -F'\t' '$2 != "-" { print $1 "\t" $2 }' "$META/lint.tsv" >>"$META/targets.tsv"
    sort -u -o "$META/targets.tsv" "$META/targets.tsv"
    # オンボード前の dir は snapshot だけ。最初の全件見直しまで scope に入れない
    while IFS=$'\t' read -r p d; do
        if onboarded "$p"; then printf '%s\t%s\n' "$p" "$d"; fi
    done <"$META/s1.tsv" >"$META/s1.on"
    mv "$META/s1.on" "$META/s1.tsv"
    if [ ! -s "$META/targets.tsv" ] && [ ! -s "$META/lint.tsv" ]; then
        log "日次: 対象なし (AI は起動しない)"
        for p in $(scope); do mkdir -p "$STATE_DIR/cursor"; s1_of "$p" >"$STATE_DIR/cursor/$p"; done
        rm -rf "$AI_DIR"
        return 0
    fi
    log "日次: 対象 $(wc -l <"$META/targets.tsv" | tr -d ' ') 件、lint $(wc -l <"$META/lint.tsv" | tr -d ' ') 件"
    prepare_work
    render_prompt daily "" >"$META/prompt.md"
    if ! run_claude "$DAILY_BUDGET_USD" "$DAILY_TIMEOUT_SEC" 150 medium "$META/out.json"; then
        fail_ai_run "claude -p が失敗した。$META/out.json.err を参照"
        return 1
    fi
    jq .structured_output "$META/out.json" >"$META/result.json"
    if ! validate_result "$META/result.json"; then fail_ai_run "出力の検証に失敗した"; return 1; fi
    apply_all daily
    intake_proposals
    finish_ai_run
}

run_full() { # run_full <p> [seed]
    local p=$1 seed=${2:-} d q n i batch spent=0 remaining note
    d=$(mem_path "$p")
    if [ -z "$(topic_files "$d")" ]; then log "全件: $p にメモリが無い"; return 1; fi
    start_ai_run "full-$p"
    for q in $( (discover_dirs; printf '%s\n' "$p") | sort -u); do
        if [ "$q" = "$p" ] || onboarded "$q"; then printf '%s\t%s\n' "$q" "$(snapshot "$(mem_path "$q")")" >>"$META/s1.tsv"; fi
    done
    topic_files "$d" | prefix "$p" >"$META/all-targets.tsv"
    cp "$META/all-targets.tsv" "$META/targets.tsv"
    lint_dir "$p" | prefix "$p" >"$META/lint.tsv"
    n=$(wc -l <"$META/all-targets.tsv" | tr -d ' ')
    log "全件: $p ($n 件、$FULL_BATCH 件ずつ)"
    prepare_work
    if [ -n "$seed" ] && [ -f "$seed" ]; then cp "$seed" "$WORK/seed.md"; fi
    i=0
    batch=0
    : >"$META/results.jsonl"
    while [ "$i" -lt "$n" ]; do
        batch=$((batch + 1))
        remaining=$(awk -v a="$FULL_BUDGET_USD" -v s="$spent" 'BEGIN { printf "%.2f", a - s }')
        if awk -v r="$remaining" 'BEGIN { exit !(r < 1) }'; then fail_ai_run "全件の予算 $FULL_BUDGET_USD USD を使い切った"; return 1; fi
        sed -n "$((i + 1)),$((i + FULL_BATCH))p" "$META/all-targets.tsv" >"$META/targets.tsv"
        note="全件の見直し。バッチ $batch (対象ファイル以外も、統合のためなら編集してよい)"
        if [ -f "$WORK/seed.md" ]; then note="${note}。seed.md は前回の手動の分類結果。根拠を確かめて使い、分類し直さない"; fi
        render_prompt full "$note" >"$META/prompt.md"
        if ! run_claude "$remaining" "$FULL_TIMEOUT_SEC" 400 high "$META/out-$batch.json"; then
            fail_ai_run "全件のバッチ $batch で claude -p が失敗した"
            return 1
        fi
        spent=$(awk -v s="$spent" -v c="$(jq '.total_cost_usd // 0' "$META/out-$batch.json")" 'BEGIN { print s + c }')
        jq -c .structured_output "$META/out-$batch.json" >>"$META/results.jsonl"
        i=$((i + FULL_BATCH))
    done
    jq -s '{changes: (map(.changes) | add), proposals: (map(.proposals) | add), needs_human: (map(.needs_human) | add)}' "$META/results.jsonl" >"$META/result.json"
    if ! validate_result "$META/result.json"; then fail_ai_run "出力の検証に失敗した"; return 1; fi
    apply_all full "$p"
    intake_proposals
    if [ -n "$seed" ] && [ -f "$seed" ]; then mv "$seed" "$seed.used"; fi
    log "全件: $p 完了 (費用 $spent USD)"
    finish_ai_run
}

pick_full() { # 全件の見直しが FULL_INTERVAL_DAYS 以上前 (か、まだ) の dir を 1 つ。seed のあるもの、メモリの多いものから
    # 共有も含める。他の dir から移されたメモリは maintenance コミットでしか入らず、日次の対象にならないため
    local p last n
    for p in $(discover_dirs); do
        n=$(topic_files "$(mem_path "$p")" | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] || continue
        last=$(cat "$STATE_DIR/full-done/$p" 2>/dev/null || echo 0)
        [ $(( (NOW - last) / 86400 )) -ge "$FULL_INTERVAL_DAYS" ] || continue
        printf '%s\t%s\t%s\n' "$([ -f "$STATE_DIR/seed/$p.md" ] && echo 1 || echo 0)" "$n" "$p"
    done | sort -t$'\t' -k1,1nr -k2,2nr | head -n 1 | cut -f3
}

dry_report() {
    local p d cursor
    for p in $(discover_dirs); do
        d=$(mem_path "$p")
        if [ ! -e "$d/.git" ]; then log "$p: git 未管理 (次の実行で snapshot する)"; continue; fi
        if ! onboarded "$p"; then log "$p: オンボード前 (全件の見直しを待つ)"; continue; fi
        cursor=$(cat "$STATE_DIR/cursor/$p" 2>/dev/null || true)
        log "$p: 対象 $(dir_targets "$p" "$cursor" | tr '\n' ' ')"
        log "$p: snapshot 前の変更 $(git -C "$d" status --porcelain | cut -c4- | tr '\n' ' ')"
        lint_dir "$p" | while IFS=$'\t' read -r f msg; do log "$p: lint $f $msg"; done
    done
    log "次の全件の見直し: $(pick_full)"
    log "提案: $(proposals_all | jq -rs 'group_by(.status) | map("\(.[0].status) \(length)") | join(", ")')"
}

main() {
    local mode=${1:-daily} seed="" p
    if [ -f "$CLAUDE_HOME/settings.json" ] && [ -n "$(jq -r '.autoMemoryDirectory // ""' "$CLAUDE_HOME/settings.json")" ]; then
        notify "autoMemoryDirectory が設定されている。memory dir の場所の前提が崩れるので止まる"
        exit 1
    fi
    mkdir -p "$STATE_DIR"
    if [ "$DRY_RUN" != "1" ]; then
        if ! mkdir "$STATE_DIR/lock" 2>/dev/null; then
            p=$(cat "$STATE_DIR/lock/pid" 2>/dev/null || true)
            if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then log "前の実行 (pid $p) が動いている。終了"; exit 0; fi
            rm -rf "$STATE_DIR/lock"
            mkdir "$STATE_DIR/lock"
        fi
        echo $$ >"$STATE_DIR/lock/pid"
        trap 'rm -rf "$STATE_DIR/lock"' EXIT
        mkdir -p "$CACHE_DIR/runs"
        find "$CACHE_DIR/runs" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    fi
    RUN_DIR="$CACHE_DIR/runs/$(date +%Y%m%d-%H%M%S)-$$"
    PMETA="$RUN_DIR/meta"
    mkdir -p "$PMETA"
    DOTFILES_P=$(encode "$DOTFILES_DIR")
    ME=$(gh api user -q .login 2>/dev/null || echo "")
    build_repo_map

    if [ "$DRY_RUN" = "1" ]; then dry_report; rm -rf "$RUN_DIR"; exit 0; fi

    if [ ! -d "$SHARED_DIR" ]; then
        mkdir -p "$SHARED_DIR"
        printf '# Shared memory — topic ファイルは %s/ にある\n\n' "$SHARED_DIR" >"$SHARED_DIR/MEMORY.md"
    fi

    case "$mode" in
        daily)
            try run_daily
            try cleanup
            try dispatch
            p=$(pick_full)
            if [ -n "$p" ]; then
                if [ -f "$STATE_DIR/seed/$p.md" ]; then seed="$STATE_DIR/seed/$p.md"; fi
                try run_full "$p" "$seed"
            fi ;;
        full)
            [ -n "${2:-}" ] || { echo "usage: $0 full <p> [--seed <file>]" >&2; exit 2; }
            if [ "${3:-}" = "--seed" ]; then seed=${4:-}; fi
            run_full "$2" "$seed" ;;
        *) echo "usage: $0 [daily | full <p> [--seed <file>]]" >&2; exit 2 ;;
    esac
    log "完了"
}

main "$@"
