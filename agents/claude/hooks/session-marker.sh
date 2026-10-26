#!/bin/bash
# SessionStart hook: Orca のターミナルで対話の Claude が始まったら、セッションごとに印を 1 つ置く。
# Mac の再起動でエージェントが全部止まったとき、home/scripts/agent-resume.sh がこの印から
# 「止まる直前まで生きていたセッション」を見つけて Orca のタブで再開する。
# 印は <起動時刻> <claude の pid> <Orca の worktree id> <cwd> <会話記録のパス> の 1 行。
#
# 何も出力しない (SessionStart の標準出力は会話の文脈に入るため)。
set -u

[ -n "${ORCA_WORKTREE_ID:-}" ] || exit 0
# claude -p (sdk-cli) は再開しない。親の Orca のターミナルから ORCA_WORKTREE_ID を継いでいても対象外。
[ "${CLAUDE_CODE_ENTRYPOINT:-}" = "cli" ] || exit 0

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input")
[ -n "$sid" ] || exit 0

dir="$HOME/Library/Application Support/agent-resume/sessions"
mkdir -p "$dir"
# "{ sec = 1792979048, usec = 168067 } Mon Oct 26 ..." の sec。
boot=$(sysctl -n kern.boottime | sed -E 's/^\{ sec = ([0-9]+),.*/\1/')
# hook の親は claude のプロセス。
pid=$PPID

# /clear や /branch は同じプロセスのまま別のセッションに切り替わる。前のセッションの印は消す。
for f in "$dir"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r b p _ <"$f" || continue
    [ "$b" = "$boot" ] && [ "$p" = "$pid" ] && rm -f "$f"
done

printf '%s\t%s\t%s\t%s\t%s\n' "$boot" "$pid" "$ORCA_WORKTREE_ID" \
    "$(jq -r '.cwd' <<<"$input")" "$(jq -r '.transcript_path' <<<"$input")" >"$dir/$sid"
