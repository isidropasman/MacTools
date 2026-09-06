import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StoreError: Error {
    case open(String)
    case exec(String)
    case prepare(String)
}

final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.isidropasman.mactools.store")

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // El nombre de la carpeta se queda en "Pila": renombrarla perderia el historial,
        // las tareas y el estante que ya estan adentro.
        let current = base.appendingPathComponent("Pila", isDirectory: true)

        // The app shipped briefly as "MacTools"; carry that history over instead of orphaning it.
        let legacy = base.appendingPathComponent("MacTools", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: current.path)
        {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return current
    }()

    static let imagesDirectory = supportDirectory.appendingPathComponent("images", isDirectory: true)
    static let thumbsDirectory = supportDirectory.appendingPathComponent("thumbs", isDirectory: true)

    /// The history holds whatever the user copied, secrets included, so nothing here is world-readable.
    /// The default umask would leave 0755 directories and 0644 files.
    private static func restrictPermissions(_ path: String, directory: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: directory ? 0o700 : 0o600],
            ofItemAtPath: path
        )
    }

    private static func hardenExistingFiles() {
        for directory in [supportDirectory, imagesDirectory, thumbsDirectory] {
            self.restrictPermissions(directory.path, directory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in contents {
                let child = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
                self.restrictPermissions(child.path, directory: isDirectory.boolValue)
            }
        }
    }

    init() throws {
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.createDirectory(at: Self.thumbsDirectory, withIntermediateDirectories: true, attributes: attributes)
        Self.hardenExistingFiles()

        let path = Self.supportDirectory.appendingPathComponent("history.sqlite").path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StoreError.open(path)
        }
        self.db = handle
        try self.migrate()

        // The -wal and -shm siblings only exist once the connection is open.
        for suffix in ["", "-wal", "-shm"] {
            Self.restrictPermissions(path + suffix, directory: false)
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(self.db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw StoreError.exec(message)
        }
    }

    private func migrate() throws {
        try self.exec("PRAGMA journal_mode = WAL;")
        try self.exec("PRAGMA synchronous = NORMAL;")
        // Without this SQLite only marks deleted pages free, leaving the text readable in the raw file.
        try self.exec("PRAGMA secure_delete = ON;")
        try self.exec("""
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            text TEXT,
            image_path TEXT,
            thumb_path TEXT,
            hash TEXT NOT NULL UNIQUE,
            source TEXT NOT NULL,
            source_app TEXT,
            external_id TEXT UNIQUE,
            byte_size INTEGER NOT NULL DEFAULT 0,
            pinned INTEGER NOT NULL DEFAULT 0,
            favorite INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_items_updated ON items(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_kind ON items(kind);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(text, content='items', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
            INSERT INTO items_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text) VALUES('delete', old.id, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
            INSERT INTO items_fts(items_fts, rowid, text) VALUES('delete', old.id, old.text);
            INSERT INTO items_fts(rowid, text) VALUES (new.id, new.text);
        END;
        """)

        // Added after the first release; fails harmlessly once the column exists.
        try? self.exec("ALTER TABLE items ADD COLUMN title TEXT;")

        // Schema 2 puts `title` in the search index, so a renamed image is findable by its name.
        if self.userVersion < 2 {
            try self.exec("""
            DROP TRIGGER IF EXISTS items_ai;
            DROP TRIGGER IF EXISTS items_ad;
            DROP TRIGGER IF EXISTS items_au;
            DROP TABLE IF EXISTS items_fts;
            CREATE VIRTUAL TABLE items_fts USING fts5(text, title, content='items', content_rowid='id');
            CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
                INSERT INTO items_fts(rowid, text, title) VALUES (new.id, new.text, new.title);
            END;
            CREATE TRIGGER items_ad AFTER DELETE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, text, title) VALUES('delete', old.id, old.text, old.title);
            END;
            CREATE TRIGGER items_au AFTER UPDATE ON items BEGIN
                INSERT INTO items_fts(items_fts, rowid, text, title) VALUES('delete', old.id, old.text, old.title);
                INSERT INTO items_fts(rowid, text, title) VALUES (new.id, new.text, new.title);
            END;
            INSERT INTO items_fts(items_fts) VALUES('rebuild');
            PRAGMA user_version = 2;
            """)
        }

        // secure_delete only zeroes future deletes. Everything deleted before this release is still
        // sitting in free pages, so purge it once.
        if self.userVersion < 3 {
            try? self.exec("VACUUM;")
            try self.exec("PRAGMA user_version = 3;")
        }

        // Rows written under the old "MacTools" support directory hold absolute paths that the
        // directory rename invalidates, so repoint them at the current location.
        try self.exec("""
        UPDATE items
        SET image_path = replace(image_path, '/Application Support/MacTools/', '/Application Support/Pila/'),
            thumb_path = replace(thumb_path, '/Application Support/MacTools/', '/Application Support/Pila/')
        WHERE image_path LIKE '%/Application Support/MacTools/%'
           OR thumb_path LIKE '%/Application Support/MacTools/%';
        """)
    }

    private var userVersion: Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writes

    /// Returns true when a new row was created; false when an existing identical item was bumped to the top.
    @discardableResult
    func upsertText(
        _ text: String,
        source: ClipSource,
        sourceApp: String?,
        externalID: String? = nil,
        at date: Date? = nil
    ) -> Bool {
        self.queue.sync {
            let digest = Self.hash(Data(text.utf8))
            let now = (date ?? Date()).timeIntervalSince1970

            if let existing = self.rowID(forHash: digest) {
                // A dictation can already be present from the clipboard watcher. Claim the row for the
                // external id, otherwise hasExternalID never returns true and the ingestor retries forever.
                if let externalID {
                    self.adopt(id: existing, externalID: externalID, source: source)
                }
                self.bump(id: existing, at: now)
                return false
            }

            var statement: OpaquePointer?
            let sql = """
            INSERT OR IGNORE INTO items (kind, text, hash, source, source_app, external_id, byte_size, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, ClipKind.text.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, text, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, digest, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, source.rawValue, -1, sqliteTransient)
            if let sourceApp { sqlite3_bind_text(statement, 5, sourceApp, -1, sqliteTransient) } else { sqlite3_bind_null(statement, 5) }
            if let externalID { sqlite3_bind_text(statement, 6, externalID, -1, sqliteTransient) } else { sqlite3_bind_null(statement, 6) }
            sqlite3_bind_int64(statement, 7, Int64(text.utf8.count))
            sqlite3_bind_double(statement, 8, now)
            sqlite3_bind_double(statement, 9, now)

            return sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(self.db) > 0
        }
    }

    @discardableResult
    func upsertImage(data: Data, fileExtension: String, thumbnail: Data?, sourceApp: String?) -> Bool {
        self.queue.sync {
            let digest = Self.hash(data)
            let now = Date().timeIntervalSince1970

            if let existing = self.rowID(forHash: digest) {
                self.bump(id: existing, at: now)
                return false
            }

            let imageURL = Self.imagesDirectory.appendingPathComponent("\(digest).\(fileExtension)")
            let thumbURL = Self.thumbsDirectory.appendingPathComponent("\(digest).png")
            do {
                try data.write(to: imageURL, options: .atomic)
                Self.restrictPermissions(imageURL.path, directory: false)
                if let thumbnail {
                    try thumbnail.write(to: thumbURL, options: .atomic)
                    Self.restrictPermissions(thumbURL.path, directory: false)
                }
            } catch {
                return false
            }

            var statement: OpaquePointer?
            let sql = """
            INSERT OR IGNORE INTO items (kind, image_path, thumb_path, hash, source, source_app, byte_size, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, ClipKind.image.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, imageURL.path, -1, sqliteTransient)
            if thumbnail != nil {
                sqlite3_bind_text(statement, 3, thumbURL.path, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_text(statement, 4, digest, -1, sqliteTransient)
            sqlite3_bind_text(statement, 5, ClipSource.clipboard.rawValue, -1, sqliteTransient)
            if let sourceApp { sqlite3_bind_text(statement, 6, sourceApp, -1, sqliteTransient) } else { sqlite3_bind_null(statement, 6) }
            sqlite3_bind_int64(statement, 7, Int64(data.count))
            sqlite3_bind_double(statement, 8, now)
            sqlite3_bind_double(statement, 9, now)

            return sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(self.db) > 0
        }
    }

    /// Loaded once so the ingestor can filter in memory instead of asking per entry, per cycle.
    func externalIDs() -> Set<String> {
        self.queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, "SELECT external_id FROM items WHERE external_id IS NOT NULL;", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            var ids: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0) { ids.insert(String(cString: raw)) }
            }
            return ids
        }
    }

    func hasExternalID(_ externalID: String) -> Bool {
        self.queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, "SELECT 1 FROM items WHERE external_id = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, externalID, -1, sqliteTransient)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func rowID(forHash digest: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, "SELECT id FROM items WHERE hash = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, digest, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func adopt(id: Int64, externalID: String, source: ClipSource) {
        var statement: OpaquePointer?
        let sql = "UPDATE items SET external_id = ?, source = ? WHERE id = ? AND external_id IS NULL;"
        guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, externalID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, source.rawValue, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 3, id)
        sqlite3_step(statement)
    }

    private func bump(id: Int64, at timestamp: TimeInterval) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, "UPDATE items SET updated_at = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    func setPinned(_ pinned: Bool, id: Int64) {
        self.setFlag("pinned", value: pinned, id: id)
    }

    func setFavorite(_ favorite: Bool, id: Int64) {
        self.setFlag("favorite", value: favorite, id: id)
    }

    private func setFlag(_ column: String, value: Bool, id: Int64) {
        self.queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, "UPDATE items SET \(column) = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, value ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
        }
    }

    func setTitle(_ title: String?, id: Int64) {
        self.queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, "UPDATE items SET title = ? WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                sqlite3_bind_text(statement, 1, trimmed, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(statement, 1)
            }
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
        }
    }

    /// Wipes history and every stored image file. Callers are responsible for confirming first.
    func deleteAll() {
        self.queue.sync {
            try? self.exec("DELETE FROM items;")
            // The dialog promises the data is gone. Without checkpoint + VACUUM the text stays
            // readable in free pages and in the write-ahead log.
            try? self.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            try? self.exec("VACUUM;")
            for directory in [Self.imagesDirectory, Self.thumbsDirectory] {
                let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for file in contents { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    func delete(id: Int64) {
        self.queue.sync {
            let paths = self.filePaths(forID: id)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, "DELETE FROM items WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            if sqlite3_step(statement) == SQLITE_DONE {
                for path in paths { try? FileManager.default.removeItem(atPath: path) }
            }
        }
    }

    private func filePaths(forID id: Int64) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, "SELECT image_path, thumb_path FROM items WHERE id = ?;", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return [] }
        return [0, 1].compactMap { index in
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
    }

    // MARK: - Reads

    enum Filter {
        case all
        case dictations
        case favorites
        case images
    }

    func items(query: String, filter: Filter, limit: Int = 300) -> [ClipItem] {
        self.queue.sync {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var conditions: [String] = []

            switch filter {
            case .all: break
            case .dictations: conditions.append("items.source = 'fluidvoice'")
            case .favorites: conditions.append("items.favorite = 1")
            case .images: conditions.append("items.kind = 'image'")
            }

            var sql: String
            if trimmed.isEmpty {
                let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
                sql = """
                SELECT items.id, kind, text, image_path, thumb_path, source, source_app, byte_size, pinned, favorite, created_at, updated_at, title
                FROM items \(whereClause)
                ORDER BY pinned DESC, updated_at DESC LIMIT \(limit);
                """
            } else {
                conditions.append("items_fts MATCH ?")
                sql = """
                SELECT items.id, kind, text, image_path, thumb_path, source, source_app, byte_size, pinned, favorite, created_at, updated_at, title
                FROM items JOIN items_fts ON items_fts.rowid = items.id
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY pinned DESC, rank LIMIT \(limit);
                """
            }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else {
                return trimmed.isEmpty ? [] : self.likeFallback(query: trimmed, filter: filter, limit: limit)
            }
            defer { sqlite3_finalize(statement) }

            if !trimmed.isEmpty {
                sqlite3_bind_text(statement, 1, Self.ftsQuery(trimmed), -1, sqliteTransient)
            }

            var results: [ClipItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let item = Self.decode(statement) { results.append(item) }
            }
            if results.isEmpty, !trimmed.isEmpty {
                return self.likeFallback(query: trimmed, filter: filter, limit: limit)
            }
            return results
        }
    }

    /// FTS5 treats bare punctuation as syntax, so every token is quoted and given a prefix wildcard.
    private static func ftsQuery(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace })
            .map { token in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }

    private func likeFallback(query: String, filter: Filter, limit: Int) -> [ClipItem] {
        var conditions = ["text LIKE ?"]
        switch filter {
        case .all: break
        case .dictations: conditions.append("source = 'fluidvoice'")
        case .favorites: conditions.append("favorite = 1")
        case .images: conditions.append("kind = 'image'")
        }
        let sql = """
        SELECT id, kind, text, image_path, thumb_path, source, source_app, byte_size, pinned, favorite, created_at, updated_at, title
        FROM items WHERE \(conditions.joined(separator: " AND "))
        ORDER BY pinned DESC, updated_at DESC LIMIT \(limit);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "%\(query)%", -1, sqliteTransient)

        var results: [ClipItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = Self.decode(statement) { results.append(item) }
        }
        return results
    }

    private static func decode(_ statement: OpaquePointer?) -> ClipItem? {
        func string(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        guard let kind = string(1).flatMap(ClipKind.init(rawValue:)),
              let source = string(5).flatMap(ClipSource.init(rawValue:))
        else { return nil }

        return ClipItem(
            id: sqlite3_column_int64(statement, 0),
            kind: kind,
            text: string(2),
            imagePath: string(3),
            thumbPath: string(4),
            source: source,
            sourceApp: string(6),
            byteSize: sqlite3_column_int64(statement, 7),
            pinned: sqlite3_column_int(statement, 8) == 1,
            favorite: sqlite3_column_int(statement, 9) == 1,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
            title: string(12)
        )
    }

    func counts() -> (total: Int, images: Int, imageBytes: Int64) {
        self.queue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*), SUM(kind = 'image'), COALESCE(SUM(CASE WHEN kind = 'image' THEN byte_size ELSE 0 END), 0) FROM items;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return (0, 0, 0) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0, 0) }
            return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)), sqlite3_column_int64(statement, 2))
        }
    }

    // MARK: - Retention

    /// Text is never evicted. Images are trimmed to the newest `maxImages` and then down to `maxImageBytes`.
    func enforceRetention(maxImages: Int, maxBytes: Int64) {
        let doomed = self.queue.sync { () -> [Int64] in
            var statement: OpaquePointer?
            let sql = """
            SELECT id, byte_size FROM items
            WHERE kind = 'image' AND pinned = 0
            ORDER BY updated_at DESC;
            """
            guard sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }

            var ids: [Int64] = []
            var index = 0
            var runningBytes: Int64 = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                runningBytes += sqlite3_column_int64(statement, 1)
                index += 1
                if index > maxImages || runningBytes > maxBytes {
                    ids.append(id)
                }
            }
            return ids
        }

        for id in doomed { self.delete(id: id) }
    }
}
