import AppKit
import UserNotifications
import ServiceManagement

/// Owns the menu bar item, watches the sessions directory, and renders state.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let githubURL = "https://github.com/BenGuanRan/ClaudeBabo"
    private let notifyPrefKey = "notificationsEnabled"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StatusStore()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var refreshScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusStore.ensureDirectories()
        if UserDefaults.standard.object(forKey: notifyPrefKey) == nil {
            UserDefaults.standard.set(true, forKey: notifyPrefKey)
        }
        requestNotificationAuthorization()

        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu

        startWatching()
        // Poll every second: keeps the live elapsed timer / cost fresh and
        // recovers if the sessions directory is deleted and recreated.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        if refreshScheduled { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        if dirSource == nil { startWatching() }
        let events = store.refresh(now: Date().timeIntervalSince1970)
        for ev in events {
            switch ev.kind {
            case .needsInput:
                notify(title: "Claude 需要你的输入",
                       body: describe(ev.session, prefer: ev.session.activity))
            case .longTaskFinished:
                let mins = formatDuration(ev.session.turnMs)
                notify(title: "✅ Claude 任务完成",
                       body: "\(ev.session.dirName) · 用时 \(mins)")
            }
        }
        updateUI()
    }

    private func describe(_ s: Session, prefer: String) -> String {
        let text = prefer.isEmpty ? s.task : prefer
        return text.isEmpty ? s.dirName : "\(s.dirName) — \(text)"
    }

    // MARK: - Menu bar button

    private func updateUI() {
        let waiting = store.sessions.filter { $0.status == .waiting }.count
        let working = store.sessions.filter { $0.status == .working }.count

        let (symbol, color): (String, NSColor)
        if waiting > 0 {
            (symbol, color) = ("bell.fill", .systemOrange)
        } else if working > 0 {
            (symbol, color) = ("ellipsis.circle.fill", .systemBlue)
        } else if !store.sessions.isEmpty {
            (symbol, color) = ("checkmark.circle.fill", .systemGreen)
        } else {
            (symbol, color) = ("circle.dashed", .secondaryLabelColor)
        }

        statusItem.button?.image = symbolImage(symbol, color: color)
        statusItem.button?.imagePosition = .imageLeading
        // Show running cost next to the icon when there are active sessions.
        statusItem.button?.title = store.sessions.isEmpty
            ? ""
            : String(format: " $%.2f", store.totalCost)
        rebuildMenu()
    }

    private func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "ClaudeBabo")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        return img
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let now = Date().timeIntervalSince1970

        let head = store.sessions.isEmpty
            ? "ClaudeBabo — 无活动会话"
            : String(format: "ClaudeBabo — %d 个会话 · 合计 $%.2f",
                     store.sessions.count, store.totalCost)
        addInfo(menu, head)
        menu.addItem(.separator())

        for s in store.sessions {
            let item = NSMenuItem(title: "\(stateDot(s.status)) \(s.dirName)",
                                  action: nil, keyEquivalent: "")
            item.submenu = sessionSubmenu(s, now: now)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addAction(menu, "刷新", #selector(manualRefresh), key: "r")

        // Preferences
        let notif = addAction(menu, "启用通知", #selector(toggleNotifications))
        notif.state = notificationsEnabled ? .on : .off
        if #available(macOS 13.0, *) {
            let login = addAction(menu, "开机自启", #selector(toggleLoginItem))
            login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }

        addAction(menu, "打开配置目录", #selector(openConfig))
        addAction(menu, "项目主页 (GitHub)", #selector(openGitHub))
        menu.addItem(.separator())
        addAction(menu, "退出 ClaudeBabo", #selector(quit), key: "q")
    }

    private func sessionSubmenu(_ s: Session, now: Double) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        addInfo(sub, statusText(s, now: now))
        if !s.task.isEmpty { addInfo(sub, "📝 \(s.task)") }
        if !s.activity.isEmpty { addInfo(sub, "⚙️ \(s.activity)") }
        if !s.model.isEmpty { addInfo(sub, "🤖 \(s.model)") }
        sub.addItem(.separator())
        if s.contextTokens > 0 {
            let warn = s.exceeds200k ? " ⚠️" : ""
            addInfo(sub, "🧠 上下文 \(formatTokens(s.contextTokens))\(warn)")
        }
        if s.outputTokens > 0 { addInfo(sub, "📤 本轮输出 \(formatTokens(s.outputTokens))") }
        addInfo(sub, String(format: "💰 $%.4f", s.costUsd))
        addInfo(sub, "⏱️ 总用时 \(formatDuration(s.durationMs))")
        addInfo(sub, "✏️ +\(s.linesAdded) / -\(s.linesRemoved)")
        sub.addItem(.separator())
        let open = NSMenuItem(title: "在 Finder 中打开",
                              action: #selector(openDir(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = s.cwd
        open.isEnabled = !s.cwd.isEmpty
        sub.addItem(open)
        return sub
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String,
                           _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func statusText(_ s: Session, now: Double) -> String {
        switch s.status {
        case .working:
            let e = s.elapsed(now: now)
            return e > 0 ? "状态：工作中（已 \(formatDuration(e * 1000))）" : "状态：工作中"
        case .waiting: return "状态：轮到你了"
        case .idle:    return "状态：空闲"
        }
    }

    private func stateDot(_ s: WorkStatus) -> String {
        switch s {
        case .working: return "🔵"
        case .waiting: return "🟠"
        case .idle:    return "🟢"
        }
    }

    private func formatTokens(_ t: Int) -> String {
        if t >= 1000 { return String(format: "%.0fk", Double(t) / 1000) }
        return "\(t)"
    }

    private func formatDuration(_ ms: Double) -> String {
        let total = Int(ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    // MARK: - Actions

    @objc private func openDir(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func manualRefresh() { refresh() }

    @objc private func toggleNotifications() {
        UserDefaults.standard.set(!notificationsEnabled, forKey: notifyPrefKey)
        updateUI()
    }

    @available(macOS 13.0, *)
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("ClaudeBabo: login item toggle failed: \(error)")
        }
        updateUI()
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: StatusStore.baseDir))
    }

    @objc private func openGitHub() {
        if let url = URL(string: Self.githubURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Directory watching

    private func startWatching() {
        let fd = open(StatusStore.sessionsDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRefresh() }
        src.setCancelHandler { [weak self] in
            close(fd)
            self?.dirSource = nil
        }
        src.resume()
        dirSource = src
    }

    // MARK: - Notifications

    private var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: notifyPrefKey)
    }

    private func requestNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Uses the modern notification API when running as a proper .app bundle;
    /// falls back to `osascript` when run as a bare binary (e.g. `swift run`).
    private func notify(title: String, body: String) {
        guard notificationsEnabled else { return }
        if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        } else {
            let t = escape(title), b = escape(body)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(b)\" with title \"\(t)\""]
            try? p.run()
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
