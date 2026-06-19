#!/usr/bin/env bash
#
# ClaudeBabo uninstaller. Removes the app bundle, the installed scripts, and
# the hook/status-line entries from ~/.claude/settings.json. Your other
# settings are left untouched.
#
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
BABO_DIR="$CLAUDE_DIR/claudebabo"
SETTINGS="$CLAUDE_DIR/settings.json"
APP_DIR="$HOME/Applications/ClaudeBabo.app"

echo "==> Quitting ClaudeBabo (if running)…"
pkill -f "ClaudeBabo.app/Contents/MacOS/ClaudeBabo" 2>/dev/null || true

echo "==> Removing app bundle and scripts…"
rm -rf "$APP_DIR" "$BABO_DIR"

if [ -f "$SETTINGS" ]; then
    echo "==> Cleaning hooks + status line from settings.json…"
    cp "$SETTINGS" "$SETTINGS.claudebabo.bak"
    python3 - "$SETTINGS" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)

hooks = cfg.get("hooks", {})
for ev in list(hooks.keys()):
    kept = [g for g in hooks[ev]
            if not any(h.get("command", "").endswith("claudebabo/bin/hook.py")
                       for h in g.get("hooks", []))]
    if kept:
        hooks[ev] = kept
    else:
        del hooks[ev]
if not hooks:
    cfg.pop("hooks", None)

sl = cfg.get("statusLine")
if isinstance(sl, dict) and "claudebabo" in sl.get("command", ""):
    cfg.pop("statusLine", None)

with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
PY
fi

cat <<EOF

✅ Uninstalled.

Restart any open Claude Code sessions to drop the hooks.
A settings backup was saved to: $SETTINGS.claudebabo.bak
EOF
