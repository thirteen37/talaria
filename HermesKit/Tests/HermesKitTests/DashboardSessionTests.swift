import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardSessionTests {
    @Test
    func newSessionHasNoCachedToken() async {
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: StubHTTP(responses: [])
        )
        let snapshot = session.tokenSnapshot()
        #expect(snapshot == nil)
    }

    @Test
    func refreshFetchesIndexAndCachesExtractedToken() async throws {
        let html = try loadFixtureString("spa-index.html")
        let http = StubHTTP(responses: [
            .init(path: "/", body: Data(html.utf8))
        ])
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: http
        )

        let token = try await session.refresh()

        #expect(token == "ntHr7-4LVSWHFi7jKLvXDMYM2DVrN5kcUhwKY_KsIcM")
        let cached = session.tokenSnapshot()
        #expect(cached == "ntHr7-4LVSWHFi7jKLvXDMYM2DVrN5kcUhwKY_KsIcM")
    }

    @Test
    func refreshRaisesWhenIndexHasNoToken() async {
        let http = StubHTTP(responses: [
            .init(path: "/", body: Data("<html><body>no token</body></html>".utf8))
        ])
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: http
        )
        await #expect(throws: DashboardSessionError.tokenNotFoundInIndex) {
            _ = try await session.refresh()
        }
    }

    @Test
    func invalidateClearsCachedToken() async throws {
        let html = try loadFixtureString("spa-index.html")
        let http = StubHTTP(responses: [
            .init(path: "/", body: Data(html.utf8))
        ])
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: http
        )
        _ = try await session.refresh()
        session.invalidate()
        let cached = session.tokenSnapshot()
        #expect(cached == nil)
    }

    @Test
    func clientRetriesAfterUnauthorizedByRefreshingToken() async throws {
        // Initial cache is empty. The first request fires anonymously,
        // gets 401. The client invokes onUnauthorized, which makes the
        // session refresh by GET / → token. The retry succeeds.
        let html = try loadFixtureString("spa-index.html")
        let http = StubHTTP(responses: [
            // First /api/sessions — no token cached, 401.
            .init(path: "/api/sessions", statusCode: 401, body: Data()),
            // Session refresh via GET /.
            .init(path: "/", body: Data(html.utf8)),
            // Retry of /api/sessions — should now carry the fresh token.
            .init(
                path: "/api/sessions",
                body: try loadFixtureData("sessions-list.json")
            )
        ])
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: http
        )
        let client = session.client()

        let response = try await client.listSessions(limit: 2)

        #expect(response.sessions.count >= 1)
        // Final request must carry the freshly-scraped token.
        let lastApiRequest = try #require(
            http.recordedRequests.last(where: { $0.url?.path == "/api/sessions" })
        )
        #expect(
            lastApiRequest.value(forHTTPHeaderField: "X-Hermes-Session-Token")
                == "ntHr7-4LVSWHFi7jKLvXDMYM2DVrN5kcUhwKY_KsIcM"
        )
    }

    @Test
    func sessionsListDecodesRichFields() throws {
        let data = try loadFixtureData("sessions-list.json")
        let response = try JSONDecoder().decode(DashboardSessionsResponse.self, from: data)

        #expect(response.total == 222)
        let first = try #require(response.sessions.first)
        #expect(first.id == "20260528_142010_e9dd2892")
        #expect(first.model == "high")
        #expect(first.messageCount == 18)
        #expect(first.toolCallCount == 6)
        #expect(first.isActive == false)
        #expect(first.lastActive == 1779961285.619833)
        #expect(first.preview?.isEmpty == false)
        #expect(first.costStatus == "unknown")
        #expect(first.estimatedCostUsd == 0.0)
        #expect(first.inputTokens == 180751)
    }

    @Test
    func listSessionsForwardsMinMessages() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/sessions",
                body: try loadFixtureData("sessions-list.json")
            )
        ])
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: http
        )
        let client = session.client()

        _ = try await client.listSessions(limit: 200, minMessages: 1)

        let request = try #require(http.recordedRequests.first)
        let query = try #require(request.url?.absoluteString)
        #expect(query.contains("min_messages=1"))
        #expect(query.contains("limit=200"))
    }

    @Test
    func listSessionsOmitsMinMessagesWhenNil() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/sessions",
                body: try loadFixtureData("sessions-list.json")
            )
        ])
        let session = DashboardSession(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            http: http
        )
        let client = session.client()

        _ = try await client.listSessions(limit: 200)

        let request = try #require(http.recordedRequests.first)
        let query = try #require(request.url?.absoluteString)
        #expect(!query.contains("min_messages"))
    }

    // MARK: - Helpers

    private func loadFixtureString(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures/Dashboard"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
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
