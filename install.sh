#!/usr/bin/env bash
#
# ClaudeBabo installer.
#   1. Builds the menu bar app (release).
#   2. Assembles a proper .app bundle in ~/Applications.
#   3. Installs the hook + status line scripts into ~/.claude/claudebabo/bin.
#   4. Wires them into ~/.claude/settings.json (idempotent, with a backup).
#   5. Launches the app.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
BABO_DIR="$CLAUDE_DIR/claudebabo"
BIN_DIR="$BABO_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
APP_DIR="$HOME/Applications/ClaudeBabo.app"

echo "==> Building ClaudeBabo (release)…"
cd "$REPO"
swift build -c release
BIN="$REPO/.build/release/ClaudeBabo"

echo "==> Installing hook + status line scripts…"
mkdir -p "$BIN_DIR" "$BABO_DIR/sessions"
cp "$REPO/scripts/hook.py" "$BIN_DIR/hook.py"
cp "$REPO/scripts/statusline.py" "$BIN_DIR/statusline.py"
chmod +x "$BIN_DIR/hook.py" "$BIN_DIR/statusline.py"

echo "==> Assembling app bundle at ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN" "$APP_DIR/Contents/MacOS/ClaudeBabo"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeBabo</string>
    <key>CFBundleDisplayName</key>     <string>ClaudeBabo</string>
    <key>CFBundleIdentifier</key>      <string>com.claudebabo.app</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleExecutable</key>      <string>ClaudeBabo</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSUIElement</key>             <true/>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "==> Wiring Claude Code hooks + status line…"
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.claudebabo.bak"
echo "    (backup saved to $SETTINGS.claudebabo.bak)"

python3 - "$SETTINGS" "$BIN_DIR/hook.py" "$BIN_DIR/statusline.py" <<'PY'
import json, sys

settings_path, hook_cmd, status_cmd = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    cfg = json.load(f)

hooks = cfg.setdefault("hooks", {})

def mine(group):
    return any(h.get("command", "").endswith("claudebabo/bin/hook.py")
               for h in group.get("hooks", []))

def entry(matcher):
    e = {"hooks": [{"type": "command", "command": hook_cmd}]}
    if matcher is not None:
        e["matcher"] = matcher
    return e

# event name -> tool matcher (None where matchers don't apply)
events = {
    "SessionStart": None,
    "UserPromptSubmit": None,
    "PreToolUse": "*",
    "PostToolUse": "*",
    "Notification": None,
    "Stop": None,
    "SessionEnd": None,
}
for ev, matcher in events.items():
    group = [g for g in hooks.get(ev, []) if not mine(g)]  # drop old ClaudeBabo entries
    group.append(entry(matcher))
    hooks[ev] = group

sl = cfg.get("statusLine")
sl_cmd = sl.get("command", "") if isinstance(sl, dict) else ""
if not sl or "claudebabo" in sl_cmd:
    cfg["statusLine"] = {"type": "command", "command": status_cmd}
    print("    status line: configured (usage/cost will appear in the menu)")
else:
    print("    status line: kept your existing one — to enable usage/cost stats,")
    print("                 set statusLine.command to:")
    print("                 " + status_cmd)

with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
PY

echo "==> Launching ClaudeBabo…"
pkill -f "ClaudeBabo.app/Contents/MacOS/ClaudeBabo" 2>/dev/null || true
sleep 1
open "$APP_DIR"

cat <<EOF

✅ Installed.

  • A new icon should appear in your menu bar (⚪️ when idle).
  • Restart any open Claude Code sessions so the new hooks take effect.
  • The first time it needs your attention, macOS may ask to allow
    notifications — click Allow.

Optional: add ClaudeBabo to Login Items (System Settings ▸ General ▸
Login Items) so it starts automatically.

Uninstall any time with:  ./uninstall.sh
EOF
