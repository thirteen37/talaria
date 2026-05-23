import Foundation
import Testing
@testable import HermesKit

// Live smoke against the user's real ~/.hermes/state.db. Skipped automatically
// if the file is not present so CI on a fresh machine doesn't fail.
@Suite(.serialized)
struct HermesDBLiveSmokeTests {
    @Test
    func listAndSearchRealDatabase() async throws {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/state.db")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let db = HermesDB(configuration: HermesDBConfiguration(databaseURL: url))
        defer { Task { await db.close() } }

        let sessions = try await db.listSessions(limit: 5)
        print("[live] listSessions: \(sessions.count) row(s)")
        for s in sessions {
            print("  - \(s.id) | title=\(s.title.isEmpty ? "<nil>" : s.title) | updated=\(s.updatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil")")
        }

        // Search shouldn't throw, and FTS5 must remain available.
        let search = try await db.searchSessions(query: "hello", limit: 5)
        print("[live] searchSessions('hello'): \(search.count) row(s)")
    }
}
