#!/usr/bin/env python3
"""ClaudeBabo hook handler.

Claude Code invokes this for several hook events and passes a JSON payload on
stdin. We translate each event into a per-session status file that the menu bar
app watches:

    ~/.claude/claudebabo/sessions/<session_id>.status.json

The script must stay fast and never fail the host session, so every error is
swallowed and we always exit 0.
"""
import sys
import os
import json
import time

BASE = os.path.expanduser("~/.claude/claudebabo/sessions")


def truncate(text, limit=120):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def save(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    sid = data.get("session_id") or "default"
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    os.makedirs(BASE, exist_ok=True)
    path = os.path.join(BASE, sid + ".status.json")

    # SessionEnd: clean up this session's files and stop.
    if event == "SessionEnd":
        for suffix in (".status.json", ".usage.json"):
            try:
                os.remove(os.path.join(BASE, sid + suffix))
            except OSError:
                pass
        return

    state = load(path)
    state["session_id"] = sid
    if cwd:
        state["cwd"] = cwd
    state["event"] = event
    state["updated_at"] = time.time()
    state.setdefault("task", "")
    state.setdefault("activity", "")

    if event == "SessionStart":
        state["status"] = "idle"
        state["activity"] = ""
    elif event == "UserPromptSubmit":
        state["status"] = "working"
        state["task"] = truncate(data.get("prompt", ""))
        state["activity"] = ""
    elif event == "PreToolUse":
        state["status"] = "working"
        state["activity"] = data.get("tool_name", "")
    elif event == "PostToolUse":
        state["status"] = "working"
        state["activity"] = ""
    elif event == "Notification":
        state["status"] = "waiting"
        state["activity"] = truncate(data.get("message", ""))
    elif event == "Stop":
        state["status"] = "idle"
        state["task"] = ""
        state["activity"] = ""
    else:
        return  # unknown event: don't write

    save(path, state)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
