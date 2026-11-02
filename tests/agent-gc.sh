#!/usr/bin/env bash
# home/scripts/agent-gc.sh の判定 (judge) と、入力欄が空かの判定 (prompt-empty) を確かめる。CI と手元で回す。
#   bash tests/agent-gc.sh
# ps・lsof・orca からの収集は macOS 専用なので試さない (docs/agent-gc-design.md 9 節)。
set -u

script="$(cd "$(dirname "$0")/.." && pwd)/home/scripts/agent-gc.sh"
fail=0

# 候補になる材料。各ケースはここから 1 か所だけ変える。
base='{"pid":1,"agent":"claude","readable":true,"status":"idle","idle_sec":90000,"pressure":1,"path":"/w/a",
       "orca":{"ok":true,"found":true,"state":"done","workspace_status":"in-review","sub_states":[]}}'

judge() { # judge <説明> <期待する reason (候補なら null)> <jq で base に当てる変更>
    local got
    got=$(jq -c "$3" <<<"$base" | EXCLUDE_RE='^/w/skip' bash "$script" judge | jq -r '.reason // "null"')
    [ "$got" = "$2" ] || { echo "FAIL judge: $1 (want $2, got $got)"; fail=1; }
}

judge "候補" null '.'
judge "Codex も同じ規則" null '.agent = "codex"'
judge "pressure WARN なら 6h で候補" null '.idle_sec = 25200 | .pressure = 2'
judge "pressure NORMAL なら 7h は残す" "idle 7h" '.idle_sec = 25200'
judge "読めない" unreadable '.readable = false'
judge "readable が無い" unreadable 'del(.readable)'
judge "busy" "status=busy" '.status = "busy"'
judge "waiting" "status=waiting" '.status = "waiting"'
judge "idle_sec が無い" "idle 0h" '.idle_sec = null'
judge "Orca に届かない" orca-unreachable '.orca.ok = false'
judge "Orca にペインが無い" not-in-orca '.orca.found = false'
judge "Orca が working" "orca working" '.orca.state = "working"'
judge "subagent が working" "orca-sub working" '.orca.sub_states = ["idle", "working"]'
judge "subagent が idle と done だけなら候補" null '.orca.sub_states = ["idle", "done"]'
judge "workspace_status が無い" orca-incomplete 'del(.orca.workspace_status)'
judge "needs-decision" needs-decision '.orca.workspace_status = "needs-decision"'
judge "EXCLUDE_RE" excluded '.path = "/w/skip/x"'

prompt() { # prompt <説明> <agent> <0=空 / 1=空でない> <端末の末尾>
    printf '%s\n' "$4" | bash "$script" prompt-empty "$2"
    [ $? = "$3" ] || { echo "FAIL prompt-empty: $1"; fail=1; }
}

prompt "Claude 空" claude 0 $'❯ 前の依頼\n✻ Worked for 3m\n────\n❯ \n────\n  ◆ Opus'
prompt "Claude 書きかけ" claude 1 $'────\n❯ あとでこれを\n────'
prompt "Claude 2 行目に書きかけ" claude 1 $'────\n❯ \n  あとでこれを\n────'
prompt "Claude 罫線が無い" claude 1 $'❯'
prompt "Claude シェルに戻った" claude 1 $'Resume this session with:\n~/www/dev [ master]'
prompt "Codex 空" codex 0 $'  Worked for 3m\n› Ask Codex to do anything\n  ? for shortcuts'
prompt "Codex 書きかけ" codex 1 $'› Ask Codex to do anything\n› 次はテストを'
prompt "Codex 別の placeholder" codex 1 $'› Explain this codebase'
prompt "知らない agent" other 1 $'❯'

[ "$fail" = 0 ] && echo "ok"
exit "$fail"
