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


def read_tokens(transcript_path):
    """Parse the most recent assistant turn's token usage from the transcript.

    We read only the tail of the (potentially large) JSONL file for speed. The
    last assistant message's usage reflects the current context window size
    (input + cache) and that turn's output.
    """
    if not transcript_path or not os.path.exists(transcript_path):
        return None
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 200_000))
            tail = f.read().decode("utf-8", "ignore")
    except OSError:
        return None

    for line in reversed(tail.splitlines()):
        if '"usage"' not in line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        usage = (obj.get("message") or {}).get("usage") or {}
        if not usage:
            continue
        context = (
            (usage.get("input_tokens") or 0)
            + (usage.get("cache_creation_input_tokens") or 0)
            + (usage.get("cache_read_input_tokens") or 0)
        )
        return {"context_tokens": context, "output_tokens": usage.get("output_tokens") or 0}
    return None


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
    tokens = read_tokens(data.get("transcript_path", "")) or {}

    usage = {
        "session_id": sid,
        "model": model,
        "cwd": cwd,
        "cost_usd": cost.get("total_cost_usd", 0.0) or 0.0,
        "duration_ms": cost.get("total_duration_ms", 0) or 0,
        "lines_added": cost.get("total_lines_added", 0) or 0,
        "lines_removed": cost.get("total_lines_removed", 0) or 0,
        "context_tokens": tokens.get("context_tokens", 0),
        "output_tokens": tokens.get("output_tokens", 0),
        "exceeds_200k": bool(data.get("exceeds_200k_tokens", False)),
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
    ctx = usage["context_tokens"]
    ctx_str = "  🧠 {}k".format(round(ctx / 1000)) if ctx else ""
    print("🤖 {}  📁 {}  💰 ${:.2f}{}".format(model, dirname, usage["cost_usd"], ctx_str))


if __name__ == "__main__":
    main()
