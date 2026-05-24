import Foundation
import SQLite3

public struct HermesSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Date?
    public var cwd: String?

    public init(id: String, title: String, updatedAt: Date? = nil, cwd: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.cwd = cwd
    }
}

public struct HermesDBConfiguration: Equatable, Sendable {
    public var databaseURL: URL
    public var readOnly: Bool

    public init(databaseURL: URL, readOnly: Bool = true) {
        self.databaseURL = databaseURL
        self.readOnly = readOnly
    }

    /// Picks the right SQLite file for a profile: the bundled local Hermes
    /// directory for `.local`, or the cached remote snapshot for `.ssh`.
    public static func forProfile(_ profile: ServerProfile, remoteSnapshotPath: URL? = nil) -> HermesDBConfiguration {
        switch profile.kind {
        case .local:
            let home = profile.hermesHome.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent(".hermes", isDirectory: true)
            return HermesDBConfiguration(databaseURL: home.appendingPathComponent("state.db", isDirectory: false))
        case .ssh:
            let url = remoteSnapshotPath
                ?? FileManager.default
                    .urls(for: .cachesDirectory, in: .userDomainMask)
                    .first!
                    .appendingPathComponent("Talaria", isDirectory: true)
                    .appendingPathComponent(profile.id.uuidString, isDirectory: true)
                    .appendingPathComponent("state.db", isDirectory: false)
            return HermesDBConfiguration(databaseURL: url)
        }
    }
}

public enum HermesDBError: Error, Equatable, Sendable, LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Couldn't open Hermes database: \(message)"
        case .queryFailed(let message):
            return "Hermes database query failed: \(message)"
        }
    }
}

public enum HermesDBSortOrder: Sendable, Hashable {
    case updatedDescending
    case titleAscending
}

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public actor HermesDB {
    // The handle lives in a reference-typed box so the SQLite connection is
    // closed when the actor is deallocated even if no one called close(). We
    // can't put the cleanup in the actor's own deinit because Swift 6 forbids
    // accessing the non-Sendable OpaquePointer from a nonisolated deinit, and
    // the actor's deinit *is* nonisolated.
    private final class HandleBox: @unchecked Sendable {
        var handle: OpaquePointer?
        deinit {
            if let handle {
                sqlite3_close_v2(handle)
            }
        }
    }

    public let configuration: HermesDBConfiguration

    private let box = HandleBox()
    private var ftsAvailable: Bool?
    private let iso8601: ISO8601DateFormatter
    private let iso8601Fractional: ISO8601DateFormatter

    public init(configuration: HermesDBConfiguration) {
        self.configuration = configuration
        let baseFormatter = ISO8601DateFormatter()
        baseFormatter.formatOptions = [.withInternetDateTime]
        self.iso8601 = baseFormatter
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Fractional = fractionalFormatter
    }

    public func close() {
        if let handle = box.handle {
            sqlite3_close_v2(handle)
            box.handle = nil
        }
        ftsAvailable = nil
    }

    public func listSessions(
        sort: HermesDBSortOrder = .updatedDescending,
        limit: Int = 200
    ) throws -> [HermesSessionSummary] {
        let db = try openIfNeeded()
        return try query(db, sql: SQL.list(sort: sort)) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
        }
    }

    public func searchSessions(
        query: String,
        sort: HermesDBSortOrder = .updatedDescending,
        limit: Int = 200
    ) throws -> [HermesSessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return try listSessions(sort: sort, limit: limit)
        }

        // Escape '\' first so the ESCAPE clause sees a literal backslash; then
        // escape the LIKE wildcards. Without the first pass, a query containing
        // '\' gets silently swallowed as the escape lead-in.
        let likePattern = "%" + trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"

        let db = try openIfNeeded()
        if ftsAvailability(db: db) {
            // FTS5 is configured. The query unions message-content matches
            // (FTS) with title/id matches (LIKE) so both schemas return the
            // same row set for the same query. A MATCH failure here is most
            // likely a user-input syntax error (bare `*`, unbalanced quote,
            // stray `:`) — fall back for THIS call only without disabling
            // FTS for the rest of the session.
            if let results = try? self.query(db, sql: SQL.searchFTS(sort: sort), bind: { stmt in
                sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, likePattern, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(limit))
            }) {
                return results
            }
        }

        return try self.query(db, sql: SQL.searchLike(sort: sort)) { stmt in
            sqlite3_bind_text(stmt, 1, likePattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    private func ftsAvailability(db: OpaquePointer) -> Bool {
        if let cached = ftsAvailable {
            return cached
        }
        // One-shot schema probe: does messages_fts exist as a virtual table?
        let probe = """
            SELECT 1 FROM sqlite_master
            WHERE type IN ('table', 'view')
              AND name = 'messages_fts'
            LIMIT 1
            """
        var stmt: OpaquePointer?
        defer {
            if stmt != nil { sqlite3_finalize(stmt) }
        }
        let rc = sqlite3_prepare_v2(db, probe, -1, &stmt, nil)
        if rc != SQLITE_OK {
            ftsAvailable = false
            return false
        }
        let available = sqlite3_step(stmt) == SQLITE_ROW
        ftsAvailable = available
        return available
    }

    public func sessionInfo(id: String) throws -> HermesSessionSummary? {
        let db = try openIfNeeded()
        let results = try query(db, sql: SQL.byId) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        }
        return results.first
    }

    private func openIfNeeded() throws -> OpaquePointer {
        if let handle = box.handle {
            return handle
        }

        var db: OpaquePointer?
        let path = configuration.databaseURL.path
        // Hermes' state.db runs in WAL journal mode, which means even a
        // SQLITE_OPEN_READONLY reader normally has to create/open the `-shm`
        // and `-wal` companion files in the same directory. That surfaces as
        // a misleading `unable to open database file` failure on the first
        // query when something keeps Talaria from those files (TCC, write
        // access on a read-only mount, …). The URI form with `immutable=1`
        // tells SQLite to treat the file as a frozen snapshot — no WAL/SHM
        // initialisation, no locks — which is exactly what the sessions
        // browser wants: a consistent point-in-time view, refreshed on
        // subsequent opens.
        let flags: Int32
        let openTarget: String
        if configuration.readOnly {
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
            openTarget = "file:\(Self.uriEscapedPath(path))?immutable=1"
        } else {
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
            openTarget = path
        }
        let rc = sqlite3_open_v2(openTarget, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed (rc=\(rc))"
            if let db {
                sqlite3_close_v2(db)
            }
            throw HermesDBError.openFailed(message)
        }
        box.handle = db
        return db
    }

    /// Percent-encodes the characters SQLite's URI-mode parser treats as
    /// metacharacters (`?`, `#`, space) and the percent sign itself. Path
    /// separators stay verbatim so the absolute-path semantics survive.
    ///
    /// `%` MUST escape first: with `SQLITE_OPEN_URI`, SQLite percent-decodes
    /// the path before opening it. A literal `%` in a directory name (e.g.
    /// `/Users/foo/100%off/.hermes`) would otherwise be interpreted as the
    /// start of an escape sequence and fail with a misleading parse error
    /// (`%of` isn't a valid byte).
    static func uriEscapedPath(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%":
                out.append("%25")
            case "?", "#":
                out.append(String(format: "%%%02X", scalar.value))
            case " ":
                out.append("%20")
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private func query(
        _ db: OpaquePointer,
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) throws -> [HermesSessionSummary] {
        var stmt: OpaquePointer?
        let prepareRc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareRc == SQLITE_OK, let stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            if let stmt {
                sqlite3_finalize(stmt)
            }
            throw HermesDBError.queryFailed(message)
        }
        defer { sqlite3_finalize(stmt) }

        bind(stmt)

        var rows: [HermesSessionSummary] = []
        while true {
            let stepRc = sqlite3_step(stmt)
            if stepRc == SQLITE_ROW {
                rows.append(decodeRow(stmt))
            } else if stepRc == SQLITE_DONE {
                break
            } else {
                let message = String(cString: sqlite3_errmsg(db))
                throw HermesDBError.queryFailed(message)
            }
        }
        return rows
    }

    private func decodeRow(_ stmt: OpaquePointer) -> HermesSessionSummary {
        let id = columnString(stmt, index: 0) ?? ""
        let title = columnString(stmt, index: 1) ?? ""
        let updatedAt = columnDate(stmt, index: 2)
        let cwd = columnString(stmt, index: 3)
        return HermesSessionSummary(id: id, title: title, updatedAt: updatedAt, cwd: cwd)
    }

    private func columnString(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func columnDate(_ stmt: OpaquePointer, index: Int32) -> Date? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, index)))
        case SQLITE_FLOAT:
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(stmt, index) else {
                return nil
            }
            let text = String(cString: cString)
            if let seconds = TimeInterval(text) {
                return Date(timeIntervalSince1970: seconds)
            }
            return iso8601.date(from: text) ?? iso8601Fractional.date(from: text)
        default:
            return nil
        }
    }

    private enum SQL {
        // Upstream schema: sessions(id, title, started_at, ended_at, ...) with no cwd column.
        // Treat updated_at as the most recent event we have for the row.
        static let columns = "id, COALESCE(title, '') AS title, COALESCE(ended_at, started_at) AS updated_at, NULL AS cwd"

        // sort comes from a typed enum, so string-interpolating it into the
        // SQL is safe — no caller-controlled value reaches the ORDER BY.
        // `prefix` is empty for unaliased queries and "s." when the sessions
        // table is aliased (FTS path).
        static func orderBy(_ sort: HermesDBSortOrder, prefix: String = "") -> String {
            switch sort {
            case .updatedDescending:
                return "ORDER BY updated_at DESC, \(prefix)id DESC"
            case .titleAscending:
                return "ORDER BY title COLLATE NOCASE ASC, \(prefix)id ASC"
            }
        }

        static func list(sort: HermesDBSortOrder) -> String {
            """
            SELECT \(columns) FROM sessions
            \(orderBy(sort))
            LIMIT ?1
            """
        }

        // messages_fts is an FTS5 virtual table over message content. The
        // query unions content matches with title/id LIKE matches so both
        // schema states return the same row set.
        static func searchFTS(sort: HermesDBSortOrder) -> String {
            """
            SELECT s.id, COALESCE(s.title, '') AS title, COALESCE(s.ended_at, s.started_at) AS updated_at, NULL AS cwd
            FROM sessions s
            WHERE s.id IN (
                SELECT DISTINCT m.session_id
                FROM messages m
                JOIN messages_fts ON messages_fts.rowid = m.id
                WHERE messages_fts MATCH ?1
            )
               OR COALESCE(s.title, '') LIKE ?2 ESCAPE '\\'
               OR s.id LIKE ?2 ESCAPE '\\'
            \(orderBy(sort, prefix: "s."))
            LIMIT ?3
            """
        }

        static func searchLike(sort: HermesDBSortOrder) -> String {
            """
            SELECT \(columns) FROM sessions
            WHERE COALESCE(title, '') LIKE ?1 ESCAPE '\\' OR id LIKE ?1 ESCAPE '\\'
            \(orderBy(sort))
            LIMIT ?2
            """
        }

        static let byId = """
            SELECT \(columns) FROM sessions WHERE id = ?1 LIMIT 1
            """
    }
}
