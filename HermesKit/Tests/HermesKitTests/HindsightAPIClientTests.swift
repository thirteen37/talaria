import Foundation
import Testing
@testable import HermesKit

@Suite
struct HindsightAPIClientTests {
    // MARK: - listMemories

    @Test
    func listMemoriesDecodesPopulatedFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", body: try fixture("list-populated.json"))
        ])
        let client = makeClient(http: http)

        let page = try await client.listMemories(bank: "hermes", limit: 100, offset: 0)

        #expect(page.total == 150)
        #expect(page.limit == 100)
        #expect(page.offset == 0)
        #expect(page.items.count == 1)
        let item = try #require(page.items.first)
        #expect(item.id == "550e8400-e29b-41d4-a716-446655440000")
        #expect(item.text == "Alice works at Google on the AI team")
        #expect(item.context == "Work conversation")
        #expect(item.type == "world")
        // entities arrive as a formatted STRING on list items → split into components
        #expect(item.entities == ["Alice (PERSON)", "Google (ORGANIZATION)"])
        // `date` is the list item's timestamp field
        #expect(item.timestamp == "2024-01-15T10:30:00Z")
    }

    @Test
    func listMemoriesDecodesEmptyFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", body: try fixture("list-empty.json"))
        ])
        let client = makeClient(http: http)

        let page = try await client.listMemories(bank: "hermes")

        #expect(page.items.isEmpty)
        #expect(page.total == 0)
    }

    @Test
    func listMemoriesBuildsRequestWithPaginationAndSearch() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", body: try fixture("list-empty.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.listMemories(bank: "hermes", query: "docs", limit: 25, offset: 50)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/default/banks/hermes/memories/list")
        let items = try queryItems(request)
        #expect(items["limit"] == "25")
        #expect(items["offset"] == "50")
        #expect(items["q"] == "docs")
    }

    @Test
    func listMemoriesOmitsSearchWhenNil() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", body: try fixture("list-empty.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.listMemories(bank: "hermes")

        let request = try #require(http.recordedRequests.first)
        #expect(try queryItems(request)["q"] == nil)
    }

    // MARK: - recall

    @Test
    func recallDecodesPopulatedFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/recall", body: try fixture("recall-populated.json"))
        ])
        let client = makeClient(http: http)

        let results = try await client.recall(bank: "hermes", query: "machine learning")

        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.id == "123e4567-e89b-12d3-a456-426614174000")
        #expect(first.text == "Alice works at Google on the AI team")
        #expect(first.type == "world")
        // entities arrive as a LIST on recall results
        #expect(first.entities == ["Alice", "Google"])
        #expect(first.timestamp == "2024-01-15T10:30:00Z")
        #expect(first.tags == ["user_a", "user_b"])
        #expect(first.metadata["source"] == "slack")
    }

    @Test
    func recallDecodesEmptyFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/recall", body: try fixture("recall-empty.json"))
        ])
        let client = makeClient(http: http)

        let results = try await client.recall(bank: "hermes", query: "anything")

        #expect(results.isEmpty)
    }

    @Test
    func recallPostsQueryInBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/recall", body: try fixture("recall-empty.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.recall(bank: "hermes", query: "preferences", types: ["world"])

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/default/banks/hermes/memories/recall")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["query"] as? String == "preferences")
        #expect(json?["types"] as? [String] == ["world"])
    }

    // MARK: - auth

    @Test
    func sendsBearerHeaderWhenAPIKeyPresent() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", body: try fixture("list-empty.json"))
        ])
        let client = HindsightAPIClient(
            baseURL: URL(string: "https://api.hindsight.vectorize.io")!,
            apiKey: "secret-key",
            http: http
        )

        _ = try await client.listMemories(bank: "hermes")

        let request = try #require(http.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    }

    @Test
    func omitsAuthHeaderForLocalEmbedded() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", body: try fixture("list-empty.json"))
        ])
        let client = HindsightAPIClient(
            baseURL: URL(string: "http://127.0.0.1:8888")!,
            apiKey: nil,
            http: http
        )

        _ = try await client.listMemories(bank: "hermes")

        let request = try #require(http.recordedRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func mapsHTTPErrorStatus() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/v1/default/banks/hermes/memories/list", statusCode: 404, body: Data("not found".utf8))
        ])
        let client = makeClient(http: http)

        await #expect(throws: HindsightAPIError.self) {
            _ = try await client.listMemories(bank: "hermes")
        }
    }

    // MARK: - helpers

    private func makeClient(http: StubHTTP) -> HindsightAPIClient {
        HindsightAPIClient(
            baseURL: URL(string: "http://127.0.0.1:8888")!,
            apiKey: nil,
            http: http
        )
    }

    private func queryItems(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] { out[item.name] = item.value }
        return out
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Hindsight")
        )
        return try Data(contentsOf: url)
    }
}
