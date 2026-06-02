import Foundation
import Testing
@testable import HermesKit

/// Serves canned HTTP responses (status + ETag + body, or an error) in FIFO
/// order and records each request, so the conditional-GET / stale-fallback
/// behavior can be driven without live network.
private final class StubCatalogHTTP: DashboardHTTP, @unchecked Sendable {
    struct Stub {
        var statusCode: Int = 200
        var etag: String?
        var body: Data = Data()
        var error: Error?
    }

    private let lock = NSLock()
    private var stubs: [Stub]
    private var _requests: [URLRequest] = []

    init(_ stubs: [Stub]) { self.stubs = stubs }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub: Stub? = lock.withLock {
            _requests.append(request)
            return stubs.isEmpty ? nil : stubs.removeFirst()
        }
        guard let stub else { throw URLError(.badServerResponse) }
        if let error = stub.error { throw error }
        var headers = ["Content-Type": "application/json"]
        if let etag = stub.etag { headers["ETag"] = etag }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        return (stub.body, response)
    }
}

/// Mutable monotonic clock for TTL control.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ start: Date) { date = start }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    var now: Date { lock.withLock { date } }
}

private let indexJSON = """
{
  "version": 1,
  "generated_at": "2026-06-02T06:52:38Z",
  "skill_count": 4,
  "skills": [
    {"name": "git-commit", "description": "Make tidy commits.", "source": "official",
     "identifier": "official/dev/git-commit", "trust_level": "builtin", "tags": ["git", "vcs"]},
    {"name": "gitignore", "description": "Generate .gitignore files.", "source": "official",
     "identifier": "official/dev/gitignore", "trust_level": "builtin", "tags": ["git"]},
    {"name": "pdf-tools", "description": "Work with git-free PDFs.", "source": "github",
     "identifier": "acme/pdf-tools", "trust_level": "community", "tags": ["pdf"]},
    {"name": "weather", "description": "Fetch forecasts.", "source": "lobehub",
     "identifier": "lobehub/weather", "trust_level": "community", "tags": ["api"]}
  ]
}
"""

@Suite
struct SkillsHubCatalogTests {
    private func makeCatalog(http: DashboardHTTP, clock: TestClock, ttl: TimeInterval = 6 * 3600) -> SkillsHubCatalog {
        SkillsHubCatalog(
            indexURL: URL(string: "https://example.test/skills-index.json")!,
            cacheURL: nil,                 // memory-only — no disk bleed across tests
            ttl: ttl,
            http: http,
            now: { clock.now }
        )
    }

    @Test
    func decodesIndexAndRanksSearch() async throws {
        let http = StubCatalogHTTP([.init(etag: "v1", body: Data(indexJSON.utf8))])
        let catalog = makeCatalog(http: http, clock: TestClock(Date(timeIntervalSince1970: 0)))

        let all = try await catalog.skills()
        #expect(all.count == 4)

        let results = await catalog.search("git")
        // Ranking: name-prefix (git-commit, gitignore) before name-substring
        // (none) before description/tag match (pdf-tools matches "git-free").
        #expect(results.map(\.identifier) == [
            "official/dev/git-commit",   // name prefix, catalog order first
            "official/dev/gitignore",    // name prefix
            "acme/pdf-tools",            // description contains "git"
        ])
    }

    @Test
    func searchIsCaseInsensitiveAndMatchesTags() async throws {
        let http = StubCatalogHTTP([.init(etag: "v1", body: Data(indexJSON.utf8))])
        let catalog = makeCatalog(http: http, clock: TestClock(Date(timeIntervalSince1970: 0)))
        _ = try await catalog.skills()

        #expect(await catalog.search("PDF").map(\.identifier) == ["acme/pdf-tools"])
        #expect(await catalog.search("api").map(\.identifier) == ["lobehub/weather"]) // tag match
        #expect(await catalog.search("   ").isEmpty)                                  // blank → none
    }

    @Test
    func servesCacheWithinTTLWithoutRefetching() async throws {
        let http = StubCatalogHTTP([.init(etag: "v1", body: Data(indexJSON.utf8))])
        let catalog = makeCatalog(http: http, clock: TestClock(Date(timeIntervalSince1970: 0)))

        _ = try await catalog.skills()
        _ = try await catalog.skills()   // still fresh

        #expect(http.requests.count == 1) // only the first call hit the network
    }

    @Test
    func conditionalGet304ReusesCache() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let http = StubCatalogHTTP([
            .init(etag: "v1", body: Data(indexJSON.utf8)),  // initial 200
            .init(statusCode: 304),                         // revalidation: unchanged
        ])
        let catalog = makeCatalog(http: http, clock: clock)

        _ = try await catalog.skills()
        clock.advance(7 * 3600)                             // past the 6h TTL
        let refreshed = try await catalog.skills()

        #expect(refreshed.count == 4)                       // cached array reused
        #expect(http.requests.count == 2)
        #expect(http.requests[1].value(forHTTPHeaderField: "If-None-Match") == "v1")
    }

    @Test
    func servesStaleCacheOnNetworkFailure() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let http = StubCatalogHTTP([
            .init(etag: "v1", body: Data(indexJSON.utf8)),
            .init(error: URLError(.notConnectedToInternet)),
        ])
        let catalog = makeCatalog(http: http, clock: clock)

        _ = try await catalog.skills()
        clock.advance(7 * 3600)
        let stale = try await catalog.skills()              // network down → stale served

        #expect(stale.count == 4)
        #expect(http.requests.count == 2)
    }

    @Test
    func throwsWhenNoCacheAndNetworkFails() async throws {
        let http = StubCatalogHTTP([.init(error: URLError(.notConnectedToInternet))])
        let catalog = makeCatalog(http: http, clock: TestClock(Date(timeIntervalSince1970: 0)))

        await #expect(throws: SkillsHubCatalogError.self) {
            _ = try await catalog.skills()
        }
    }

    @Test
    func persistsAcrossInstancesViaDiskCache() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-hub-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let firstHTTP = StubCatalogHTTP([.init(etag: "v1", body: Data(indexJSON.utf8))])
        let first = SkillsHubCatalog(
            indexURL: URL(string: "https://example.test/i.json")!,
            cacheURL: cacheURL, ttl: 6 * 3600, http: firstHTTP, now: { clock.now }
        )
        _ = try await first.skills()

        // A brand-new instance with a network that always fails must still serve
        // the on-disk cache the first instance wrote.
        let secondHTTP = StubCatalogHTTP([.init(error: URLError(.notConnectedToInternet))])
        let second = SkillsHubCatalog(
            indexURL: URL(string: "https://example.test/i.json")!,
            cacheURL: cacheURL, ttl: 6 * 3600, http: secondHTTP, now: { clock.now }
        )
        // Within TTL → no network at all.
        let loaded = try await second.skills()
        #expect(loaded.count == 4)
        #expect(secondHTTP.requests.isEmpty)
    }
}
