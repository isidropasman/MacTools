#!/bin/bash
# Reports Claude Code CLI sessions to LLMPet. $1 = working | ready | end
# Conductor sessions are read straight from its SQLite db, so skip those here.
[ -n "${CONDUCTOR_AGENT_BINARIES_DIR:-}" ] && exit 0

DIR="$HOME/.llmpet/sessions"
mkdir -p "$DIR"
INPUT=$(cat)

read -r SID CWD < <(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json,sys
d = json.load(sys.stdin)
print(d.get("session_id","unknown"), d.get("cwd",""))
')
[ -z "$SID" ] && exit 0

FILE="$DIR/$SID.json"
if [ "$1" = "end" ]; then
  rm -f "$FILE"
  exit 0
fi

# The agent process is this hook's grandparent; the app polls kill(pid, 0) on it
# so a session vanishes the moment you close the terminal instead of lingering.
AGENT_PID=$(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' ')
[ -z "$AGENT_PID" ] && AGENT_PID=$PPID

/usr/bin/python3 -c '
import json,os,sys
sid, cwd, state, path, pid = sys.argv[1:6]
cwd = cwd or os.getcwd()
json.dump({
  "title": os.path.basename(cwd) or sid[:8],
  "context": cwd.replace(os.path.expanduser("~"), "~"),
  "source": "claude",
  "agent": "Claude Code",
  "origin": "terminal",
  "state": state,
  "pid": int(pid),
  "open": "file://" + cwd,
}, open(path, "w"))
' "$SID" "$CWD" "$1" "$FILE" "$AGENT_PID"
