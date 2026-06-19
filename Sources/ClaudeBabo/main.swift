import AppKit

// ClaudeBabo — a macOS menu bar app that shows the working status of your
// local Claude Code sessions. Entry point: create the app, install the
// delegate, run as an "accessory" (menu bar only, no Dock icon).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
