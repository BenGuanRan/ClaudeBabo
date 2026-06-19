import AppKit
import UserNotifications

/// Owns the menu bar item, watches the sessions directory, and renders state.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let githubURL = "https://github.com/BenGuanRan/ClaudeBabo"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StatusStore()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var refreshScheduled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusStore.ensureDirectories()
        requestNotificationAuthorization()

        statusItem.button?.title = "⚪️"
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusItem.menu = menu

        startWatching()
        // Fallback poll: keeps duration/cost fresh and recovers if the
        // sessions directory is deleted and recreated.
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
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
            case .finished:
                notify(title: "Claude 任务完成", body: ev.session.dirName)
            }
        }
        updateUI()
    }

    private func describe(_ s: Session, prefer: String) -> String {
        let text = prefer.isEmpty ? s.task : prefer
        return text.isEmpty ? s.dirName : "\(s.dirName) — \(text)"
    }

    // MARK: - UI

    private func updateUI() {
        statusItem.button?.title = aggregateTitle()
        rebuildMenu()
    }

    private func aggregateTitle() -> String {
        let waiting = store.sessions.filter { $0.status == .waiting }.count
        let working = store.sessions.filter { $0.status == .working }.count
        if waiting > 0 { return waiting > 1 ? "🟡\(waiting)" : "🟡" }
        if working > 0 { return working > 1 ? "🔵\(working)" : "🔵" }
        if !store.sessions.isEmpty { return "🟢" }
        return "⚪️"
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(
            title: store.sessions.isEmpty
                ? "ClaudeBabo — 无活动会话"
                : "ClaudeBabo — \(store.sessions.count) 个会话",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for s in store.sessions {
            let item = NSMenuItem(title: "\(emoji(s.status)) \(s.dirName)",
                                  action: nil, keyEquivalent: "")
            item.submenu = buildSessionSubmenu(s)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addAction(menu, "刷新", #selector(manualRefresh), key: "r")
        addAction(menu, "打开配置目录", #selector(openConfig))
        addAction(menu, "项目主页 (GitHub)", #selector(openGitHub))
        menu.addItem(.separator())
        addAction(menu, "退出 ClaudeBabo", #selector(quit), key: "q")
    }

    private func buildSessionSubmenu(_ s: Session) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false
        addInfo(sub, statusText(s))
        if !s.task.isEmpty { addInfo(sub, "📝 \(s.task)") }
        if !s.activity.isEmpty { addInfo(sub, "⚙️ \(s.activity)") }
        if !s.model.isEmpty { addInfo(sub, "🤖 \(s.model)") }
        addInfo(sub, String(format: "💰 $%.4f", s.costUsd))
        addInfo(sub, "⏱️ \(formatDuration(s.durationMs))")
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

    private func statusText(_ s: Session) -> String {
        switch s.status {
        case .working: return "状态：工作中"
        case .waiting: return "状态：等待输入"
        case .idle:    return "状态：空闲"
        }
    }

    private func emoji(_ s: WorkStatus) -> String {
        switch s {
        case .working: return "🔵"
        case .waiting: return "🟡"
        case .idle:    return "🟢"
        }
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

    private func requestNotificationAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Uses the modern notification API when running as a proper .app bundle;
    /// falls back to `osascript` when run as a bare binary (e.g. `swift run`).
    private func notify(title: String, body: String) {
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
