import Foundation

/// High-level working status of a Claude Code session.
enum WorkStatus: String {
    case working   // Claude is thinking / running tools
    case waiting   // Claude needs your input
    case idle      // finished or no work in progress
}

/// One Claude Code session, merged from its status file (written by hooks)
/// and its usage file (written by the status line script).
struct Session {
    var id: String
    var status: WorkStatus
    var task: String        // the current prompt / task summary
    var activity: String    // current tool / notification message
    var cwd: String
    var model: String
    var costUsd: Double
    var durationMs: Double
    var linesAdded: Int
    var linesRemoved: Int
    var contextTokens: Int
    var outputTokens: Int
    var exceeds200k: Bool
    var workStartedAt: Double  // when the current turn began (0 if not working)
    var turnMs: Double         // duration of the last completed turn
    var turnDoneAt: Double     // when the last turn finished (Stop)
    var updatedAt: Double
    var alertAt: Double        // bumped by the Notification hook; drives desktop alerts

    var dirName: String {
        if cwd.isEmpty { return "会话" }
        return (cwd as NSString).lastPathComponent
    }

    /// Seconds the current turn has been running (only meaningful while working).
    func elapsed(now: Double) -> Double {
        workStartedAt > 0 ? max(0, now - workStartedAt) : 0
    }
}

/// A status transition worth notifying the user about.
struct SessionEvent {
    enum Kind {
        case needsInput            // Notification hook: away / permission
        case longTaskFinished      // a turn longer than the threshold just ended
    }
    let kind: Kind
    let session: Session
}

/// Reads per-session JSON files and exposes a merged, sorted snapshot.
final class StatusStore {
    static let baseDir = ("~/.claude/claudebabo" as NSString).expandingTildeInPath
    static var sessionsDir: String { baseDir + "/sessions" }

    private(set) var sessions: [Session] = []
    private var lastAlert: [String: Double] = [:]
    private var lastTurnDone: [String: Double] = [:]

    /// Sessions whose files haven't been touched in this long are ignored
    /// (covers crashes that leave orphaned files behind).
    private let staleAfter: TimeInterval = 6 * 3600

    /// Only turns longer than this trigger a "task finished" notification, so
    /// quick back-and-forth chatting stays quiet.
    private let longTaskSeconds: Double = 30

    /// Total cost across the currently tracked sessions.
    var totalCost: Double { sessions.reduce(0) { $0 + $1.costUsd } }

    static func ensureDirectories() {
        try? FileManager.default.createDirectory(
            atPath: sessionsDir, withIntermediateDirectories: true)
    }

    /// Re-scan the sessions directory. Returns notification-worthy transitions
    /// detected since the previous refresh.
    func refresh(now: Double) -> [SessionEvent] {
        let dir = StatusStore.sessionsDir
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []

        var ids = Set<String>()
        for f in files where f.hasSuffix(".status.json") {
            ids.insert(String(f.dropLast(".status.json".count)))
        }

        var result: [Session] = []
        for id in ids {
            guard let st = Self.readJSON(dir + "/" + id + ".status.json") else { continue }
            let us = Self.readJSON(dir + "/" + id + ".usage.json") ?? [:]
            let updated = max(Self.num(st["updated_at"]), Self.num(us["updated_at"]))
            if now - updated > staleAfter { continue }
            let cwd = Self.str(st["cwd"]).isEmpty ? Self.str(us["cwd"]) : Self.str(st["cwd"])
            result.append(Session(
                id: id,
                status: WorkStatus(rawValue: Self.str(st["status"])) ?? .idle,
                task: Self.str(st["task"]),
                activity: Self.str(st["activity"]),
                cwd: cwd,
                model: Self.str(us["model"]),
                costUsd: Self.num(us["cost_usd"]),
                durationMs: Self.num(us["duration_ms"]),
                linesAdded: Int(Self.num(us["lines_added"])),
                linesRemoved: Int(Self.num(us["lines_removed"])),
                contextTokens: Int(Self.num(us["context_tokens"])),
                outputTokens: Int(Self.num(us["output_tokens"])),
                exceeds200k: (us["exceeds_200k"] as? Bool) ?? false,
                workStartedAt: Self.num(st["work_started_at"]),
                turnMs: Self.num(st["turn_ms"]),
                turnDoneAt: Self.num(st["turn_done_at"]),
                updatedAt: updated,
                alertAt: Self.num(st["alert_at"])))
        }
        result.sort { $0.updatedAt > $1.updatedAt }

        // Detect notification-worthy transitions, but only ones that advance
        // *while we're running*. Sessions seen for the first time (e.g. at
        // launch) are recorded silently so we don't replay a backlog.
        var events: [SessionEvent] = []
        var newAlert: [String: Double] = [:]
        var newTurnDone: [String: Double] = [:]
        for s in result {
            newAlert[s.id] = s.alertAt
            newTurnDone[s.id] = s.turnDoneAt
            if let prev = lastAlert[s.id], s.alertAt > prev {
                events.append(SessionEvent(kind: .needsInput, session: s))
            }
            if let prevDone = lastTurnDone[s.id], s.turnDoneAt > prevDone,
               s.turnMs >= longTaskSeconds * 1000 {
                events.append(SessionEvent(kind: .longTaskFinished, session: s))
            }
        }
        lastAlert = newAlert
        lastTurnDone = newTurnDone
        sessions = result
        return events
    }

    // MARK: - JSON helpers

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func str(_ v: Any?) -> String { v as? String ?? "" }

    private static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
}
