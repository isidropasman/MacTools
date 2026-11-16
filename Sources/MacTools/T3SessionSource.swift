import AppKit
import Foundation
import SQLite3

final class T3SessionSource: SessionSource {
    static let bundleID = "com.t3tools.t3code"
    static let dataDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/.t3/userdata")

    private let directory: URL
    private let appPath: String?
    private let queue = DispatchQueue(label: "notchbox.sessions.t3code", qos: .utility)
    private let lock = NSLock()
    private var cached: [LLMSession] = []
    private var polling = false

    init(dataDirectory: URL = T3SessionSource.dataDirectory,
         appPath: String? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3SessionSource.bundleID)?.path) {
        directory = dataDirectory
        self.appPath = appPath
    }

    func poll(includeTokens: Bool) -> [LLMSession] {
        lock.lock()
        let snapshot = cached
        let shouldPoll = !polling
        polling = true
        lock.unlock()

        // SessionStore polls on main; neither SQLite's busy timeout nor disk reads belong there.
        if shouldPoll {
            queue.async { [self] in
                let fresh = readSessions()
                lock.lock()
                cached = fresh
                polling = false
                lock.unlock()
            }
        }
        return snapshot
    }

    private static let query = """
        WITH visible_runs AS (
            SELECT r.* FROM orchestration_v2_projection_runs r
            WHERE r.status = 'failed' OR NOT EXISTS (
                SELECT 1 FROM orchestration_v2_projection_messages m
                WHERE m.message_id = json_extract(r.payload_json, '$.userMessageId')
                  AND m.role = 'user'
                  AND (json_extract(m.payload_json, '$.idleCompaction') IS NOT NULL
                       OR (json_extract(m.payload_json, '$.createdBy') = 'agent'
                           AND json_extract(m.payload_json, '$.creationSource') = 'server'))
                  AND lower(trim(json_extract(m.payload_json, '$.text'))) = '/compact'
                  AND COALESCE(json_array_length(m.payload_json, '$.attachments'), 0) = 0
                  AND NOT EXISTS (
                      SELECT 1 FROM orchestration_v2_projection_turn_items c
                      WHERE c.thread_id = r.thread_id AND c.run_id = r.run_id
                        AND c.type = 'compaction' AND c.status = 'failed'
                  )
            )
        )
        SELECT t.thread_id, t.title, p.title, COALESCE(a.provider, r.provider, t.default_provider),
               t.updated_at, COALESCE(a.status, r.status, 'idle'),
               COALESCE(json_extract(a.payload_json, '$.workStartedAt'),
                        json_extract(a.payload_json, '$.startedAt'), a.requested_at, ''),
               COALESCE(r.completed_at, ''),
               COALESCE(json_extract(t.payload_json, '$.lastVisitedAt'), ''),
               (json_extract(t.payload_json, '$.settledOverride') = 'settled'
                   OR json_extract(t.payload_json, '$.settledAt') IS NOT NULL),
               EXISTS (
                   SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                   WHERE q.thread_id = t.thread_id AND q.status = 'pending'
                     AND q.kind <> 'auth_refresh'
               ) OR EXISTS (
                   SELECT 1 FROM visible_runs live
                   JOIN orchestration_v2_projection_turn_items card
                     ON card.thread_id = live.thread_id AND card.run_id = live.run_id
                   WHERE live.thread_id = t.thread_id
                     AND live.status IN ('preparing', 'starting', 'running', 'waiting')
                     AND card.type = 'secret_request' AND card.status = 'waiting'
               ) OR EXISTS (
                   SELECT 1 FROM orchestration_v2_projection_turn_items card
                   WHERE card.thread_id = t.thread_id
                     AND card.type = 'link_request' AND card.status = 'waiting'
                     AND NOT EXISTS (
                         SELECT 1 FROM orchestration_v2_projection_messages reply
                         WHERE reply.thread_id = t.thread_id AND reply.role = 'user'
                           AND json_extract(reply.payload_json, '$.createdBy') = 'user'
                           AND julianday(reply.updated_at) > julianday(COALESCE(
                               json_extract(card.payload_json, '$.startedAt'), card.updated_at))
                     )
               ),
               EXISTS (
                   SELECT 1 FROM orchestration_v2_projection_turn_items stop
                   WHERE stop.thread_id = t.thread_id AND stop.run_id = r.run_id
                     AND stop.type = 'run_interrupt_request'
               )
        FROM orchestration_v2_projection_threads t
        JOIN projection_projects p ON p.project_id = t.project_id
        LEFT JOIN visible_runs a ON a.run_id = (
            SELECT run_id FROM visible_runs
            WHERE thread_id = t.thread_id
              AND status IN ('preparing', 'starting', 'running', 'waiting')
            ORDER BY ordinal DESC LIMIT 1
        )
        LEFT JOIN visible_runs r ON r.run_id = (
            SELECT run_id FROM visible_runs
            WHERE thread_id = t.thread_id
              AND NOT (status = 'queued' AND json_extract(payload_json, '$.queueHeld') IS 1)
            ORDER BY ordinal DESC LIMIT 1
        )
        WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
          AND p.archived_at IS NULL AND p.deleted_at IS NULL
          AND json_extract(t.payload_json, '$.archivedAt') IS NULL
          AND json_extract(t.payload_json, '$.deletedAt') IS NULL
          AND json_extract(t.payload_json, '$.lineage.relationshipToParent') IS NOT 'subagent'
          AND json_extract(t.payload_json, '$.lineage.sideChat') IS NOT 1
          AND (a.run_id IS NOT NULL OR julianday(t.updated_at) > julianday('now', '-1 day'))
        ORDER BY t.updated_at DESC
        LIMIT 40
        """

    private func readSessions() -> [LLMSession] {
        let path = directory.appendingPathComponent("statev2.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ raw: String) -> Date? { fractional.date(from: raw) ?? plain.date(from: raw) }

        let environment = (try? String(contentsOf: directory.appendingPathComponent("environment-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentID = environment.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
        var sessions: [LLMSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func column(_ index: Int32) -> String {
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            }
            let status = column(5)
            let activity = [date(column(4)), date(column(6)), date(column(7))].compactMap { $0 }.max()
            guard let activity else { continue }
            let settled = sqlite3_column_int(statement, 9) != 0
            let state: SessionState
            if sqlite3_column_int(statement, 10) != 0 {
                state = .ready
            } else if ["preparing", "starting", "running", "waiting"].contains(status) {
                state = .working
            } else if settled {
                state = .seen
            } else if status == "failed" {
                state = .error
            } else if status == "completed", sqlite3_column_int(statement, 11) == 0,
                      let completed = date(column(7)), completed > (date(column(8)) ?? .distantPast) {
                state = .ready
            } else {
                state = .seen
            }

            let provider = column(3)
            let agent = provider == "claudeAgent" ? "Claude Code" : provider.capitalized
            let threadID = column(0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(
                CharacterSet(charactersIn: "/?#%")))
            let openURL = environmentID.flatMap { environment in
                threadID.map { "t3code://threads/\(environment)/\($0)" }
            }
            sessions.append(LLMSession(
                id: "t3code:" + column(0),
                title: column(1).isEmpty ? String(localized: "Sin título") : column(1),
                source: "t3code",
                context: column(2),
                state: state,
                openURL: openURL,
                appPath: appPath,
                faviconURL: nil,
                tabID: nil,
                lastActivity: activity,
                activeSince: state == .working ? date(column(6)) : nil,
                tokens: nil,
                agent: agent.isEmpty ? nil : agent,
                origin: "T3 Code"
            ))
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }
}
