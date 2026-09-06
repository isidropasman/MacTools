#!/bin/bash
# Codex notify hook. Codex invokes this with one argument: a JSON blob describing
# the event. Unlike Claude Code there is no "turn started" event, so a Codex
# session shows up the first time it finishes something and then reports ready.
[ -n "${CONDUCTOR_AGENT_BINARIES_DIR:-}" ] && exit 0

DIR="$HOME/.llmpet/sessions"
mkdir -p "$DIR"

/usr/bin/python3 - "$1" "$DIR" <<'PY'
import json, os, sys

raw, directory = sys.argv[1], sys.argv[2]
try:
    event = json.loads(raw)
except (ValueError, IndexError):
    sys.exit(0)

session = event.get("session_id") or event.get("conversation_id") or "codex"
cwd = event.get("cwd") or os.getcwd()

# agent-turn-complete is the only event that means "your turn".
state = "ready" if event.get("type") == "agent-turn-complete" else "working"

path = os.path.join(directory, f"codex-{session}.json")
json.dump({
    "title": event.get("last-assistant-message", "")[:60].strip()
             or os.path.basename(cwd) or "Codex",
    "context": cwd.replace(os.path.expanduser("~"), "~"),
    "source": "codex",
    "agent": "Codex",
    "origin": "terminal",
    "state": state,
    "pid": os.getppid(),
    "open": "file://" + cwd,
}, open(path, "w"))
PY
