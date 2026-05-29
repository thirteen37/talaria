import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientTests {
    @Test
    func getStatusDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: try loadFixtureData("status.json"))
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { nil },
            http: http
        )

        let status = try await client.getStatus()

        #expect(status.version == "0.14.0")
        #expect(status.releaseDate == "2026.5.16")
    }

    @Test
    func getStatusOmitsTokenHeaderWhenNoTokenAvailable() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: try loadFixtureData("status.json"))
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { nil },
            http: http
        )

        _ = try await client.getStatus()

        let request = try #require(http.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == nil)
    }

    @Test
    func sendsTokenHeaderWhenProvided() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/sessions", body: try loadFixtureData("sessions-list.json"))
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok-abc" },
            http: http
        )

        _ = try await client.listSessions(limit: 2)

        let request = try #require(http.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok-abc")
    }

    @Test
    func listSessionsDecodesIdAndTitleAndStartedAt() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/sessions", body: try loadFixtureData("sessions-list.json"))
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )

        let response = try await client.listSessions(limit: 2)

        #expect(response.sessions.count >= 1)
        let first = try #require(response.sessions.first)
        #expect(first.id == "20260528_142010_e9dd2892")
        #expect(first.title == "Session Analysis and Improvement")
        // started_at is a UNIX epoch float in the fixture.
        #expect(first.startedAt != nil)
    }

    @Test
    func searchSessionsExposesSnippetWithoutHighlightMarkers() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/sessions/search", body: try loadFixtureData("sessions-search.json"))
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )

        let response = try await client.searchSessions(query: "hermes", limit: 2)

        let first = try #require(response.results.first)
        let displaySnippet = try #require(first.displaySnippet)
        #expect(displaySnippet.contains("/Users/hermes/.hermes/hermes-agent/hermes_constants.py"))
        #expect(!displaySnippet.contains(">>>"))
        #expect(!displaySnippet.contains("<<<"))
    }

    @Test
    func retriesOnceAfterUnauthorizedAndCallsRefresh() async throws {
        // First request: 401. Second request: 200 with fixture body. The
        // client must invoke `onUnauthorized` between the two so a caller-
        // owned cache can drop its stale token and rescrape the SPA.
        let http = StubHTTP(responses: [
            .init(path: "/api/sessions", statusCode: 401, body: Data(#"{"detail":"Unauthorized"}"#.utf8)),
            .init(path: "/api/sessions", body: try loadFixtureData("sessions-list.json"))
        ])
        let refreshCount = Counter()
        let tokens = TokenSequence(["stale", "fresh"])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { tokens.next() },
            onUnauthorized: { refreshCount.increment() },
            http: http
        )

        let response = try await client.listSessions(limit: 2)

        #expect(response.sessions.count >= 1)
        #expect(refreshCount.value == 1)
        // Two requests in total — confirms the retry actually happened.
        #expect(http.recordedRequests.count == 2)
        #expect(http.recordedRequests[0].value(forHTTPHeaderField: "X-Hermes-Session-Token") == "stale")
        #expect(http.recordedRequests[1].value(forHTTPHeaderField: "X-Hermes-Session-Token") == "fresh")
    }

    @Test
    func raisesUnauthorizedAfterRefreshStillFails() async throws {
        // Both attempts return 401. The client must not loop forever — it
        // surfaces the second failure to the caller.
        let http = StubHTTP(responses: [
            .init(path: "/api/sessions", statusCode: 401, body: Data()),
            .init(path: "/api/sessions", statusCode: 401, body: Data())
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            onUnauthorized: {},
            http: http
        )
        await #expect(throws: DashboardClientError.unauthorized) {
            _ = try await client.listSessions(limit: 1)
        }
        #expect(http.recordedRequests.count == 2)
    }

    @Test
    func updateActionStatusDecodesNotRunning() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/actions/hermes-update/status",
                body: try loadFixtureData("update-status.json")
            )
        ])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )

        let action = try await client.getUpdateActionStatus()

        #expect(action.name == "hermes-update")
        #expect(action.running == false)
        #expect(action.lines.isEmpty)
    }

    private func loadFixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures/Dashboard"
            )
        )
        return try Data(contentsOf: url)
    }
}

/// Captures requests and serves canned responses in FIFO order. The retry-
/// on-401 tests need the same path to return different bodies on successive
/// requests, so we pop from the head of the queue rather than match by path.
final class StubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "StubHTTP")
    private var responses: [Response]
    private var _recordedRequests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var recordedRequests: [URLRequest] {
        queue.sync { _recordedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let popped: Response? = queue.sync {
            _recordedRequests.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard
            let url = request.url,
            let match = popped,
            url.path == match.path
        else {
            throw URLError(.unsupportedURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: match.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (match.body, response)
    }
}

/// Counts calls from a `@Sendable` closure under Swift 6 strict concurrency.
/// Class-with-lock rather than an actor so test assertions can read `.value`
/// synchronously without scattering `await` across every check.
final class Counter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Counter")
    private var _value: Int = 0
    var value: Int { queue.sync { _value } }
    func increment() { queue.sync { _value += 1 } }
}

/// Hands out a sequence of token strings from a `@Sendable () -> String?`
/// closure. Each call pops the next entry; once exhausted, returns nil.
final class TokenSequence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenSequence")
    private var values: [String]

    init(_ values: [String]) { self.values = values }

    func next() -> String? {
        queue.sync { values.isEmpty ? nil : values.removeFirst() }
    }
}
