# ClaudeBabo

A tiny macOS **menu bar** app that shows the live working status of your local
**Claude Code** sessions — at a glance, from the top of your screen.

> 一个小巧的 macOS 菜单栏应用，实时显示本地 Claude Code 会话的工作状态。

```
⚪️  no active session        🟢  idle
🔵  working (thinking/tools)  🟡  waiting for your input
```

Click the icon to see, for each session:

- **Status** — working / waiting / idle
- **Current task** — the prompt Claude is working on
- **Activity** — the tool it's running right now
- **Usage** — model, cost (USD), duration, lines added/removed
- A shortcut to open that session's folder in Finder

You also get a **macOS notification** when Claude needs your input or finishes a
task — so you can switch away and get pulled back at the right moment.

## How it works

ClaudeBabo is just a viewer. Claude Code does the reporting through its built-in
extension points:

```
Claude Code session
   │  hooks (SessionStart, UserPromptSubmit, PreToolUse, Notification, Stop, …)
   ▼
~/.claude/claudebabo/bin/hook.py        → sessions/<id>.status.json
~/.claude/claudebabo/bin/statusline.py  → sessions/<id>.usage.json
   │  (the menu bar app watches this folder)
   ▼
ClaudeBabo.app  →  menu bar icon + dropdown + notifications
```

- **Hooks** report status and the current task/tool.
- The **status line** script is the only place Claude Code exposes cost/usage,
  so ClaudeBabo installs itself as your status line to capture it (it still
  prints a normal status line at the bottom of Claude Code).

Nothing leaves your machine. No network access, no telemetry.

## Requirements

- macOS 12 or newer
- [Claude Code](https://claude.com/claude-code)
- Swift toolchain — the **Xcode Command Line Tools** are enough
  (`xcode-select --install`); full Xcode is *not* required
- `python3` (ships with the Command Line Tools)

## Install

```bash
git clone https://github.com/BenGuanRan/ClaudeBabo.git
cd ClaudeBabo
./install.sh
```

The installer builds the app, places `ClaudeBabo.app` in `~/Applications`,
installs the hook scripts, and wires them into `~/.claude/settings.json`
(a backup is written to `settings.json.claudebabo.bak`).

Then:

1. **Restart any open Claude Code sessions** so the new hooks load.
2. Click **Allow** if macOS asks about notifications.
3. (Optional) Add ClaudeBabo to **System Settings ▸ General ▸ Login Items** so
   it starts on boot.

No Gatekeeper warning: because you build from source, the binary runs unsigned
without the "unidentified developer" prompt.

## Scope: global, per-user

The hooks live in your **user-level** `~/.claude/settings.json`, so ClaudeBabo
tracks **all** Claude Code sessions for your macOS user — in any project, any
terminal. It does not affect other users on the machine. To limit it to a
single project instead, move the `hooks` / `statusLine` blocks into that
project's `.claude/settings.json`.

## Uninstall

```bash
./uninstall.sh
```

Removes the app, the scripts, and only the ClaudeBabo entries from your
settings (a backup is saved first). Restart open Claude Code sessions to finish.

## Notes & limitations

- **Existing status line:** if you already have a custom `statusLine`, the
  installer keeps it and prints the command to add manually. Until then,
  status/task still work — only cost/usage need the status line.
- Status is event-driven; the menu refreshes within ~0.2s of a change and polls
  every 3s as a fallback.
- Sessions are keyed by Claude Code's session id; stale files (>6h untouched)
  are ignored, and `SessionEnd` cleans them up.

## Contributing

Issues and PRs welcome. The codebase is small:

| Path | What it is |
|------|------------|
| `Sources/ClaudeBabo/` | the Swift menu bar app |
| `scripts/hook.py` | translates hook events → status JSON |
| `scripts/statusline.py` | captures usage → usage JSON + prints status line |
| `install.sh` / `uninstall.sh` | setup + teardown |

Build for development:

```bash
swift build          # debug build at .build/debug/ClaudeBabo
swift run            # run directly (notifications fall back to osascript)
```

## License

[MIT](LICENSE)
