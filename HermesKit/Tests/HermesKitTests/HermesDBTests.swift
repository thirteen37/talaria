import Foundation
import SQLite3
import Testing
@testable import HermesKit

@Suite
struct HermesDBTests {
    @Test
    func listSessionsOrdersByUpdatedDesc() async throws {
        let fixture = try Fixture.make(withFTS: true)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        let sessions = try await db.listSessions()
        #expect(sessions.count == 5)
        let ids = sessions.map(\.id)
        // Inserted with started_at = 100..500 for ids s1..s5; ended_at null for s5 so it picks started_at.
        #expect(ids == ["s5", "s4", "s3", "s2", "s1"])
        #expect(sessions.first?.cwd == nil) // no cwd column in upstream schema
    }

    @Test
    func listSessionsByTitleSorts() async throws {
        let fixture = try Fixture.make(withFTS: true)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        let sessions = try await db.listSessions(sort: .titleAscending)
        let titles = sessions.map(\.title)
        #expect(titles == titles.sorted())
    }

    @Test
    func searchSessionsUsesMessagesFTS() async throws {
        let fixture = try Fixture.make(withFTS: true)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        // s3 has a message containing "lambda" in the fixture.
        let results = try await db.searchSessions(query: "lambda")
        #expect(results.count == 1)
        #expect(results.first?.id == "s3")
    }

    @Test
    func searchRespectsSortOrder() async throws {
        let fixture = try Fixture.make(withFTS: true)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        // Query "session" — matches none of the inserted message bodies but
        // matches every session id via the LIKE branch (id starts with "s"),
        // so we cover both FTS and LIKE paths in one query.
        let byRecent = try await db.searchSessions(query: "s", sort: .updatedDescending)
        let byTitle = try await db.searchSessions(query: "s", sort: .titleAscending)

        #expect(byRecent.map(\.id) != byTitle.map(\.id))
        #expect(byTitle.map(\.title) == byTitle.map(\.title).sorted())
    }

    @Test
    func searchByTitleReturnsSameResultsWithOrWithoutFTS() async throws {
        // Title "deep dive" exists; only message body contains "lambda".
        // A title-only match should hit on both paths so behaviour doesn't
        // depend on whether messages_fts is configured.
        let withFTS = try Fixture.make(withFTS: true)
        defer { withFTS.cleanup() }
        let withoutFTS = try Fixture.make(withFTS: false)
        defer { withoutFTS.cleanup() }

        let dbA = HermesDB(configuration: HermesDBConfiguration(databaseURL: withFTS.url))
        defer { Task { await dbA.close() } }
        let dbB = HermesDB(configuration: HermesDBConfiguration(databaseURL: withoutFTS.url))
        defer { Task { await dbB.close() } }

        let resultsA = try await dbA.searchSessions(query: "deep")
        let resultsB = try await dbB.searchSessions(query: "deep")
        #expect(resultsA.map(\.id) == resultsB.map(\.id))
        #expect(resultsA.contains { $0.id == "s3" })
    }

    @Test
    func searchTolaratesPerQuerySyntaxErrorsWithoutDisablingFTS() async throws {
        let fixture = try Fixture.make(withFTS: true)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        // First a valid match, to seed FTS availability as true.
        _ = try await db.searchSessions(query: "lambda")

        // FTS5 rejects a bare colon prefix. We should fall back to LIKE for this
        // call without permanently disabling FTS for the actor.
        let weird = try await db.searchSessions(query: ":")
        _ = weird // result is whatever LIKE returns; we just care it didn't throw.

        // The next valid FTS query should still hit FTS (single match for 'lambda').
        let again = try await db.searchSessions(query: "lambda")
        #expect(again.count == 1)
        #expect(again.first?.id == "s3")
    }

    @Test
    func searchFallsBackToLikeWhenFTSMissing() async throws {
        let fixture = try Fixture.make(withFTS: false)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        let results = try await db.searchSessions(query: "alpha")
        #expect(results.contains { $0.id == "s1" })
    }

    @Test
    func likeFallbackEscapesBackslashInQuery() async throws {
        let fixture = try Fixture.make(withFTS: false, extraTitles: ["path\\with\\slash"])
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        // Without the backslash escape, this would silently return no rows
        // because the '\' starts an escape sequence under ESCAPE '\\'.
        let results = try await db.searchSessions(query: "path\\with")
        #expect(results.contains { $0.title.contains("path\\with\\slash") })
    }

    @Test
    func sessionInfoReturnsNilForMissing() async throws {
        let fixture = try Fixture.make(withFTS: true)
        defer { fixture.cleanup() }
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: fixture.url))
        defer { Task { await db.close() } }

        let hit = try await db.sessionInfo(id: "s2")
        #expect(hit?.title.contains("beta") == true)
        let miss = try await db.sessionInfo(id: "does-not-exist")
        #expect(miss == nil)
    }

    @Test
    func uriEscapedPathEscapesPercentFirst() {
        // SQLite percent-decodes the URI path with SQLITE_OPEN_URI; a literal
        // `%` in the directory name (e.g. `/Users/foo/100%off/.hermes`) must
        // be percent-encoded itself or SQLite reads `%of` as a malformed
        // escape and fails to open the file.
        let escaped = HermesDB.uriEscapedPath("/Users/foo/100%off/data.db")
        #expect(escaped == "/Users/foo/100%25off/data.db")
        // And the encoding must not double-escape: a path with a `?` shows
        // its `%3F` escape with the `%` itself intact, not `%253F`.
        let withQuestion = HermesDB.uriEscapedPath("/tmp/why?.db")
        #expect(withQuestion == "/tmp/why%3F.db")
        let withSpace = HermesDB.uriEscapedPath("/tmp/has space.db")
        #expect(withSpace == "/tmp/has%20space.db")
    }

    @Test
    func openSucceedsForPathContainingPercent() async throws {
        // End-to-end: a percent in the parent directory must survive both
        // our escaping and SQLite's URI decoding round-trip.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-uri-\(UUID().uuidString)-100%off", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("state.db")
        // Create a real (if minimal) SQLite file at the % path so the
        // read-only open has something valid to attach to.
        var seed: OpaquePointer?
        let seedRc = sqlite3_open_v2(dbURL.path, &seed, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        #expect(seedRc == SQLITE_OK)
        if let seed {
            _ = sqlite3_exec(seed, "CREATE TABLE sessions (id TEXT, title TEXT, started_at REAL NOT NULL, ended_at REAL);", nil, nil, nil)
            sqlite3_close_v2(seed)
        }

        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: dbURL))
        defer { Task { await db.close() } }
        // Reaching the empty-result path proves the URI form opened the
        // file under the `%`-containing directory.
        let rows = try await db.listSessions()
        #expect(rows.isEmpty)
    }

    @Test
    func openFailsForMissingFile() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-missing-\(UUID().uuidString).db")
        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: missing))
        defer { Task { await db.close() } }

        await #expect(throws: HermesDBError.self) {
            _ = try await db.listSessions()
        }
    }
}

private struct Fixture {
    let url: URL

    static func make(withFTS: Bool, extraTitles: [String] = []) throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-fixture-\(UUID().uuidString).db")
        try? FileManager.default.removeItem(at: url)

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            throw FixtureError.openFailed
        }
        defer { sqlite3_close_v2(db) }

        // Upstream sessions schema (subset matching real ~/.hermes/state.db).
        try exec(db, """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                title TEXT,
                started_at REAL NOT NULL,
                ended_at REAL
            );
            """)
        try exec(db, """
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT,
                timestamp REAL NOT NULL
            );
            """)

        if withFTS {
            try exec(db, """
                CREATE VIRTUAL TABLE messages_fts USING fts5(content);
                """)
        }

        let rows: [(id: String, title: String, started: Int, ended: Int?, message: String)] = [
            ("s1", "alpha refactor", 100, 110, "alpha groundwork message"),
            ("s2", "beta investigation", 200, 210, "beta findings"),
            ("s3", "deep dive", 300, 310, "lambda calculus exploration"),
            ("s4", "delta cleanup", 400, 410, "delta sweep"),
            ("s5", "epsilon spike", 500, nil, "epsilon trial"),
        ]
        for row in rows {
            let ended = row.ended.map { String($0) } ?? "NULL"
            try exec(db, """
                INSERT INTO sessions (id, title, started_at, ended_at) VALUES ('\(row.id)', '\(row.title)', \(row.started), \(ended));
                """)
            try exec(db, """
                INSERT INTO messages (session_id, role, content, timestamp) VALUES ('\(row.id)', 'user', '\(row.message)', \(row.started));
                """)
            if withFTS {
                try exec(db, """
                    INSERT INTO messages_fts (rowid, content) VALUES (last_insert_rowid(), '\(row.message)');
                    """)
            }
        }

        for (index, title) in extraTitles.enumerated() {
            // Quote each backslash; SQLite uses '' to escape single quotes,
            // backslash is a literal so it survives as-is in the stored value.
            let escaped = title.replacingOccurrences(of: "'", with: "''")
            let started = 1000 + index
            try exec(db, """
                INSERT INTO sessions (id, title, started_at, ended_at)
                VALUES ('extra-\(index)', '\(escaped)', \(started), NULL);
                """)
        }

        return Fixture(url: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "sqlite_exec failed"
            if let err {
                sqlite3_free(err)
            }
            throw FixtureError.execFailed(message)
        }
    }

    enum FixtureError: Error {
        case openFailed
        case execFailed(String)
    }
}
