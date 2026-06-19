#!/usr/bin/env python3
"""ClaudeBabo status line.

Claude Code calls this to render its own bottom status line, passing a rich
JSON payload (model, workspace, cost) on stdin. We do two things:

  1. Record usage (model, cost, duration, line counts) for the menu bar app:
        ~/.claude/claudebabo/sessions/<session_id>.usage.json
  2. Print a compact status line back to Claude Code's bottom bar.

This is the only place cost/usage data is available, which is why ClaudeBabo
also installs itself as your status line.
"""
import sys
import os
import json
import time

BASE = os.path.expanduser("~/.claude/claudebabo/sessions")


def main():
    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        data = {}

    sid = data.get("session_id") or "default"
    model = (data.get("model") or {}).get("display_name", "Claude")
    workspace = data.get("workspace") or {}
    cwd = workspace.get("current_dir") or data.get("cwd", "")
    cost = data.get("cost") or {}

    usage = {
        "session_id": sid,
        "model": model,
        "cwd": cwd,
        "cost_usd": cost.get("total_cost_usd", 0.0) or 0.0,
        "duration_ms": cost.get("total_duration_ms", 0) or 0,
        "lines_added": cost.get("total_lines_added", 0) or 0,
        "lines_removed": cost.get("total_lines_removed", 0) or 0,
        "updated_at": time.time(),
    }

    try:
        os.makedirs(BASE, exist_ok=True)
        path = os.path.join(BASE, sid + ".usage.json")
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(usage, f)
        os.replace(tmp, path)
    except OSError:
        pass

    dirname = os.path.basename(cwd) if cwd else "~"
    print("🤖 {}  📁 {}  💰 ${:.2f}".format(model, dirname, usage["cost_usd"]))


if __name__ == "__main__":
    main()
