import Foundation

struct TokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    /// Cache reads are the bulk of the raw count and cost a fraction of fresh
    /// input, so billing them at face value makes every long session look
    /// identical. This is the number worth showing.
    var billable: Int { input + output + cacheWrite }
    var total: Int { billable + cacheRead }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
}

/// Claude Code appends one JSON object per line to
/// ~/.claude/projects/<slug>/<session-id>.jsonl, and every assistant message
/// carries a `usage` block. Conductor stores the matching id in
/// sessions.claude_session_id, which is what makes the join possible.
///
/// ponytail: parses only the bytes appended since the last read and keeps the
/// running total per file. Re-reading multi-MB transcripts every 2s poll would
/// dwarf everything else this app does.
final class TranscriptIndex {
    static let shared = TranscriptIndex()

    private static let chunkSize = 2 * 1024 * 1024

    private struct Entry {
        var offset: UInt64 = 0
        var usage = TokenUsage()
    }

    private var entries: [String: Entry] = [:]
    private var paths: [String: String] = [:]
    private let root = NSHomeDirectory() + "/.claude/projects"

    func usage(sessionID: String) -> TokenUsage? {
        guard !sessionID.isEmpty, let path = locate(sessionID) else { return nil }
        var entry = entries[sessionID] ?? Entry()

        guard let handle = FileHandle(forReadingAtPath: path) else { return entry.usage }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let end = UInt64(size)
        if end < entry.offset { entry = Entry() }  // file was rewritten
        guard end > entry.offset else { return entry.usage }

        // Read a bounded slice, not readToEnd(): individual transcripts reach
        // 46 MB here, and pulling one into memory whole spiked resident size to
        // ~156 MB. Anything past the chunk is picked up on the next poll, so a
        // large backlog just takes a few passes to catch up.
        try? handle.seek(toOffset: entry.offset)
        guard let data = try? handle.read(upToCount: Self.chunkSize), !data.isEmpty
        else { return entry.usage }

        // Only consume whole lines; a partial trailing line is re-read next poll.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return entry.usage }
        let complete = data[..<lastNewline]

        for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            entry.usage = entry.usage + TokenUsage(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0
            )
        }
        entry.offset += UInt64(complete.count) + 1
        entries[sessionID] = entry
        return entry.usage
    }

    private var indexedAt = Date.distantPast

    /// When the transcript was last appended to — the closest thing to a live
    /// "this session is streaming right now" signal for hosts that expose no state.
    func lastWrite(sessionID: String) -> Date? {
        guard let path = locate(sessionID) else { return nil }
        return try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    /// Most sessions have no transcript at all. Probing per session meant
    /// rescanning every project directory on every poll for each miss, which
    /// burned ~10% CPU at idle. One directory sweep, cached, answers everything —
    /// including the misses.
    private func locate(_ sessionID: String) -> String? {
        if Date().timeIntervalSince(indexedAt) > 60 { reindex() }
        return paths[sessionID]
    }

    private func reindex() {
        indexedAt = Date()
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return }
        var found: [String: String] = [:]
        for project in projects {
            let dir = "\(root)/\(project)"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                found[String(file.dropLast(6))] = "\(dir)/\(file)"
            }
        }
        paths = found
    }
}

func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return "\(count / 1000)k" }
    return "\(count)"
}
