import AppKit
import Foundation
import SQLite3

enum SessionState: String {
    case working, ready, error, seen
}

struct LLMSession: Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
    let context: String
    let state: SessionState
    let openURL: String?
    /// App whose real icon represents this session (Conductor, Chrome, ...).
    let appPath: String?
    /// Second, smaller icon layered on the app one — the site's favicon for web
    /// sessions, so you see "Chrome + ChatGPT" rather than just "Chrome".
    let faviconURL: String?
    /// Browser tab id, the only stable handle for "raise *that* tab".
    let tabID: Int?
    let lastActivity: Date
    /// When the current turn started — how long it has been working, which is a
    /// different question from when it last emitted anything.
    let activeSince: Date?
    let tokens: TokenUsage?
    /// "Claude" / "Codex" — which agent is actually running in there.
    let agent: String?
    /// Where it runs: "Conductor", "cloud", "terminal", or the site name.
    let origin: String

    var appName: String? {
        appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }
}

protocol SessionSource {
    /// `includeTokens` is false while the list is hidden. Token counts are only
    /// ever rendered inside the open list, and computing them means reading every
    /// transcript — pure waste when all that is on screen is the badge.
    func poll(includeTokens: Bool) -> [LLMSession]
}

// MARK: - Conductor

/// Conductor is a Tauri app that keeps every session in a local SQLite db.
/// `unread_count > 0` is exactly "finished and you haven't looked at it yet".
final class ConductorSource: SessionSource {
    private static let dbPath = NSHomeDirectory()
        + "/Library/Application Support/com.conductor.app/conductor.db"

    private static let query = """
        SELECT s.id,
               COALESCE(NULLIF(s.title, ''), 'Untitled'),
               s.status,
               s.unread_count,
               COALESCE(NULLIF(w.workspace_name, ''), w.directory_name, ''),
               w.id,
               s.updated_at,
               COALESCE(s.last_user_message_at, ''),
               COALESCE(s.claude_session_id, ''),
               COALESCE(s.agent_type, ''),
               w.repository_id,
               COALESCE(w.sandbox_provider, '') || COALESCE(w.hosting_server_url, '')
        FROM sessions s
        JOIN workspaces w ON w.id = s.workspace_id
        WHERE w.archive_commit IS NULL
          AND s.is_hidden = 0
          AND s.updated_at > datetime('now', ?)
        ORDER BY s.updated_at DESC
        LIMIT 40
        """

    /// Conductor writes timestamps in two shapes depending on which code path
    /// created the row: "2026-09-01 15:27:42" and "2026-09-01T18:41:06.943Z".
    /// Parsing only the first turned newer rows into distantPast, which is where
    /// the "739861d" entries came from.
    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parseDate(_ raw: String) -> Date? {
        plain.date(from: raw) ?? iso.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }

    /// last_user_message_at is ISO8601 with milliseconds, unlike updated_at.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var db: OpaquePointer?
    private let window: String

    init(window: String = "-1 day") {
        self.window = window
    }

    deinit { sqlite3_close(db) }

    private func connect() -> OpaquePointer? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return nil }
        let uri = "file:\(Self.dbPath)?mode=ro"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        db = handle
        return handle
    }

    func poll(includeTokens: Bool) -> [LLMSession] {
        guard let db = connect() else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, window, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var out: [LLMSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            let status = col(2)
            let unread = sqlite3_column_int(stmt, 3)
            let state: SessionState
            switch status {
            case "working": state = .working
            case "error": state = .error
            // Conductor uses 'waiting' for "the agent stopped and needs you".
            // Missing this made those sessions show up as plain grey.
            case "waiting": state = .ready
            default: state = unread > 0 ? .ready : .seen
            }
            out.append(LLMSession(
                id: "conductor:" + col(0),
                title: col(1),
                source: "conductor",
                context: col(4),
                state: state,
                openURL: Config.shared.conductorLink(
                    repo: col(10), workspace: col(5), session: col(0)),
                appPath: "/Applications/Conductor.app",
                faviconURL: nil,
                tabID: nil,
                lastActivity: Self.parseDate(col(6)) ?? .distantPast,
                activeSince: state == .working ? Self.parseDate(col(7)) : nil,
                tokens: includeTokens ? TranscriptIndex.shared.usage(sessionID: col(8)) : nil,
                agent: col(9).isEmpty ? nil : col(9).capitalized,
                origin: col(11).isEmpty ? "Conductor" : "Conductor · cloud"
            ))
        }
        return out
    }
}

// MARK: - Drop-in JSON

/// Anything that isn't Conductor reports by dropping a file in ~/.llmpet/sessions/.
/// Claude Code hooks write it directly; the Chrome extension posts to the local
/// listener which writes the same shape.
struct FileSource: SessionSource {
    static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/.llmpet/sessions")

    /// The browser extension re-posts every open tab every 5s, so anything that
    /// hasn't been heard from in half a minute is a tab that is genuinely gone.
    private let heartbeatGrace: TimeInterval = 30

    func poll(includeTokens: Bool) -> [LLMSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var out: [LLMSession] = []
        for url in files where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = raw["title"] as? String
            else { continue }

            let source = raw["source"] as? String ?? "claude"
            let browser = raw["browser"] as? String

            // Liveness. A row you cannot click through to is worse than no row,
            // so each source has to prove it still exists:
            //   browser tabs  -> a heartbeat within the last 30s
            //   terminal CLIs -> the agent process is still alive
            let alive: Bool
            if source == "chrome" {
                alive = Date().timeIntervalSince(modified) < heartbeatGrace
            } else if let pid = raw["pid"] as? Int32 {
                alive = kill(pid, 0) == 0 || errno == EPERM
            } else {
                alive = Date().timeIntervalSince(modified) < 12 * 3600
            }
            guard alive else {
                try? fm.removeItem(at: url)
                continue
            }
            out.append(LLMSession(
                id: source + ":" + url.deletingPathExtension().lastPathComponent,
                title: title,
                source: source,
                context: raw["context"] as? String ?? "",
                state: SessionState(rawValue: raw["state"] as? String ?? "") ?? .seen,
                openURL: raw["open"] as? String,
                appPath: browser.map { "/Applications/\($0).app" },
                faviconURL: raw["favicon"] as? String,
                tabID: raw["tabId"] as? Int,
                lastActivity: modified,
                activeSince: (raw["activeSince"] as? Double).map {
                    Date(timeIntervalSince1970: $0)
                },
                tokens: nil,
                agent: raw["agent"] as? String,
                origin: raw["origin"] as? String ?? (source == "chrome" ? "web" : "terminal")
            ))
        }
        return out
    }
}

// MARK: - Aggregation

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [LLMSession] = []

    private let sources: [SessionSource] = [ConductorSource(), FileSource(), ClaudeDesktopSource()]
    private var timer: Timer?

    var readyCount: Int { visible.filter { $0.state == .ready }.count }

    /// With the list closed the only thing on screen is the badge, so a slow tick
    /// is indistinguishable from a fast one — and each tick costs a SQL query plus
    /// a directory walk. Open, it needs to feel live.
    private static let openInterval: TimeInterval = 1.5
    private static let idleInterval: TimeInterval = 6

    private(set) var detailsVisible = false

    func start() {
        refresh()
        schedule()
    }

    /// Called when the list opens or closes. Switching both the cadence and the
    /// token work here is what keeps the app near zero while it is just sitting there.
    func setDetailsVisible(_ visible: Bool) {
        guard visible != detailsVisible else { return }
        detailsVisible = visible
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        let interval = detailsVisible ? Self.openInterval : Self.idleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common, otherwise polling stalls while a menu or drag tracking loop runs.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sections in the order you actually need to act on them.
    static let sectionOrder: [(state: SessionState, title: String)] = [
        (.ready, "Esperando respuesta"),
        (.working, "Activas"),
        (.error, "Con error"),
        (.seen, "Finalizadas"),
    ]

    @Published private(set) var shelfVersion = 0

    var visible: [LLMSession] {
        let pinned = Shelf.pinned
        return sessions.filter { pinned.contains($0.id) || !Shelf.isHidden($0) }
    }

    var sections: [(state: SessionState, title: String, sessions: [LLMSession])] {
        let pinned = Shelf.pinned
        return Self.sectionOrder.compactMap { section in
            let matching = visible
                .filter { $0.state == section.state }
                .sorted {
                    let (a, b) = (pinned.contains($0.id), pinned.contains($1.id))
                    return a == b ? $0.lastActivity > $1.lastActivity : a
                }
            return matching.isEmpty ? nil : (section.state, section.title, matching)
        }
    }

    func dismiss(_ session: LLMSession) {
        Shelf.dismiss(session)
        shelfVersion += 1
    }

    func togglePin(_ session: LLMSession) {
        Shelf.togglePin(session.id)
        shelfVersion += 1
    }

    /// Token spend rolled up by workspace, biggest first.
    var projectUsage: [(name: String, usage: TokenUsage)] {
        var totals: [String: TokenUsage] = [:]
        for session in sessions {
            guard let usage = session.tokens, usage.billable > 0 else { continue }
            let key = session.context.isEmpty ? "—" : session.context
            totals[key] = (totals[key] ?? TokenUsage()) + usage
        }
        return totals.map { (name: $0.key, usage: $0.value) }
            .sorted { $0.usage.billable > $1.usage.billable }
    }

    var totalUsage: TokenUsage {
        sessions.compactMap(\.tokens).reduce(TokenUsage(), +)
    }

    func refresh() {
        let fresh = sources.flatMap { $0.poll(includeTokens: detailsVisible) }
            .sorted { $0.lastActivity > $1.lastActivity }
        if fresh != sessions { sessions = fresh }
    }

    func open(_ session: LLMSession) {
        if session.source == "chrome" {
            focusBrowserTab(session)
            return
        }
        guard let raw = session.openURL, let url = URL(string: raw) else { return }

        // macOS only lets the *active* application hand focus to another one, and
        // this is an .accessory app whose panels never activate it. Clicking a row
        // while Chrome was frontmost meant the raise request came from a
        // background app, so the system dropped it and Conductor stayed behind.
        // Activating ourselves first is what earns the right to pass focus along;
        // for an agent app with no windows of its own it is imperceptible.
        if session.source == "conductor" {
            // Deliver the route, then raise. Delivery was never the problem.
            NSWorkspace.shared.open(url)
            activateViaAppleEvent(bundleID: "com.conductor.app")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}

/// Delivering the URL always worked; raising the window did not. macOS only lets
/// the *active* app hand focus to another, and an LSUIElement app with
/// non-activating panels never qualifies — so NSWorkspace's activation, and
/// /usr/bin/open launched as our child (which inherits the same background
/// context), were both dropped whenever Chrome was frontmost.
///
/// An Apple Event asks the target to activate *itself*, which is a request macOS
/// always honours regardless of who is frontmost. Verified: Conductor becomes the
/// frontmost process.
private func activateViaAppleEvent(bundleID: String) {
    var error: NSDictionary?
    NSAppleScript(source: "tell application id \"\(bundleID)\" to activate")?
        .executeAndReturnError(&error)
    if let error {
        NSLog("llmpet: no pude activar \(bundleID): \(error)")
        // Automation not granted yet — at least get the app launched.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
    }
}

/// Raises the *existing* tab. Matching is by Chrome's own tab id — the URL is
/// useless as a handle because chat apps rewrite it as the conversation grows.
///
/// Deliberately never falls back to NSWorkspace.open: spawning a duplicate tab
/// is worse than doing nothing, since it loses the session you were pointing at.
@discardableResult
private func focusBrowserTab(_ session: LLMSession) -> Bool {
    guard let tabID = session.tabID, let app = session.appName else {
        NSSound.beep()
        return false
    }
    let script = """
    tell application "\(app)"
      repeat with w in windows
        set i to 0
        repeat with t in tabs of w
          set i to i + 1
          if (id of t) is \(tabID) then
            set active tab index of w to i
            set index of w to 1
            activate
            return "ok"
          end if
        end repeat
      end repeat
    end tell
    return "missing"
    """
    var error: NSDictionary?
    let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
    if let error {
        // -1743 is "user has not granted Automation access to this app".
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        NSLog("llmpet: no pude enfocar la pestaña (\(code)) \(error)")
        if code == -1743 { openAutomationSettings() }
        NSSound.beep()
        return false
    }
    if result?.stringValue != "ok" {
        NSSound.beep()  // tab is gone; the reporter will drop it on the next poll
        return false
    }
    return true
}

private func openAutomationSettings() {
    guard let url = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    else { return }
    NSWorkspace.shared.open(url)
}

/// `llmpet --check` — smallest thing that fails if the Conductor query or the
/// status→state mapping breaks.
func runSelfCheck() -> Never {
    // Transcripts are consumed 2 MB per pass, so a single poll under-reports.
    // The running app converges over successive polls; here we drain first.
    let source = ConductorSource(window: "-30 day")
    var sessions = source.poll(includeTokens: true)
    var previous = -1
    while true {
        let total = sessions.compactMap { $0.tokens }.reduce(TokenUsage(), +).billable
        if total == previous { break }
        previous = total
        sessions = source.poll(includeTokens: true)
    }
    assert(!sessions.isEmpty, "Conductor query returned nothing — schema changed?")
    for s in sessions {
        assert(!s.title.isEmpty, "empty title for \(s.id)")
        // Never emit a conductor:// URL that isn't the open-workspace shape:
        // anything else is parsed as "create-workspace" on the other side.
        if let link = s.openURL, link.hasPrefix("conductor:") {
            assert(link.hasPrefix("conductor://workspace?id="),
                   "unsafe Conductor deep link would create a workspace: \(link)")
        }
        assert(s.lastActivity > .distantPast, "unparsed timestamp for \(s.id)")
        assert(Date().timeIntervalSince(s.lastActivity) < 400 * 86400,
               "absurd age for \(s.id) — timestamp format not recognised")
    }
    assert(zip(sessions, sessions.dropFirst()).allSatisfy { $0.lastActivity >= $1.lastActivity },
           "sessions are not ordered by last activity")
    let working = sessions.filter { $0.state == .working }
    print("conductor: \(sessions.count) sesiones, \(working.count) working, "
        + "\(sessions.filter { $0.state == .ready }.count) ready")
    for s in sessions.prefix(5) {
        let tokens = s.tokens.map { " · \(formatTokens($0.billable)) tok" } ?? " · sin transcript"
        print("  [\(s.state.rawValue)] \(s.context.isEmpty ? "-" : s.context) — \(s.title)\(tokens)")
    }
    let withTokens = sessions.compactMap { $0.tokens }.filter { $0.billable > 0 }
    assert(!withTokens.isEmpty, "no parsed usage from any transcript")
    print("transcripts con uso: \(withTokens.count)/\(sessions.count), "
        + "total \(formatTokens(withTokens.reduce(TokenUsage(), +).billable)) tokens")
    print("files: \(FileSource().poll(includeTokens: true).count) sesiones")
    print("OK")
    exit(0)
}
