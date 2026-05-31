import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientConfigTests {
    @Test
    func getConfigSchemaDecodesFieldsInOrder() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config/schema", body: try loadFixtureData("config-schema.json"))
        ])
        let client = makeClient(http: http)

        let schema = try await client.getConfigSchema()

        #expect(schema.field(for: "terminal.backend")?.type == .select)
        #expect(schema.orderedKeys.first == "model")
        #expect(schema.categoryOrder.first == "general")
    }

    @Test
    func getConfigSchemaIsPublicButStillSendsTokenWhenAvailable() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config/schema", body: try loadFixtureData("config-schema.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.getConfigSchema()

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/config/schema")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    }

    @Test
    func getConfigReturnsJSONValueVerbatim() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config", body: try loadFixtureData("config-get.json"))
        ])
        let client = makeClient(http: http)

        let config = try await client.getConfig()

        guard case .object(let root) = config,
              case .object(let terminal) = root["terminal"] else {
            Issue.record("expected nested config object")
            return
        }
        #expect(root["model"] == .string("anthropic/claude-sonnet-4.6"))
        #expect(root["model_context_length"] == .number(0))
        #expect(terminal["backend"] == .string("local"))
    }

    @Test
    func updateConfigPutsConfigWrappedBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)
        let config = JSONValue.object([
            "model": .string("anthropic/x"),
            "agent": .object(["streaming": .bool(false)]),
        ])

        try await client.updateConfig(config)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/config")
        // Body must be wrapped under a top-level `config` key (the dashboard's
        // ConfigUpdate model), not the bare config object.
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(ConfigUpdateProbe.self, from: body)
        guard case .object(let sent) = decoded.config,
              case .object(let agent) = sent["agent"] else {
            Issue.record("expected wrapped config object")
            return
        }
        #expect(sent["model"] == .string("anthropic/x"))
        #expect(agent["streaming"] == .bool(false))
    }

    @Test
    func getSoulReturnsMarkdownContent() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles/default/soul", body: Data(##"{"content":"# Soul\nBe concise.\n","exists":true}"##.utf8))
        ])
        let client = makeClient(http: http)

        let content = try await client.getSoul(profile: "default")

        #expect(content == "# Soul\nBe concise.\n")
        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/profiles/default/soul")
    }

    @Test
    func updateSoulPutsContentWrappedBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles/default/soul", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.updateSoul(profile: "default", content: "# Soul\nBe pragmatic.\n")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/profiles/default/soul")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(SoulUpdateProbe.self, from: body)
        #expect(decoded.content == "# Soul\nBe pragmatic.\n")
    }

    @Test
    func getConfigRetriesOnceAfterUnauthorized() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config", statusCode: 401, body: Data(#"{"detail":"Unauthorized"}"#.utf8)),
            .init(path: "/api/config", body: try loadFixtureData("config-get.json")),
        ])
        let refreshCount = Counter()
        let tokens = TokenSequence(["stale", "fresh"])
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { tokens.next() },
            onUnauthorized: { refreshCount.increment() },
            http: http
        )

        _ = try await client.getConfig()

        #expect(refreshCount.value == 1)
        #expect(http.recordedRequests.count == 2)
        #expect(http.recordedRequests[1].value(forHTTPHeaderField: "X-Hermes-Session-Token") == "fresh")
    }

    @Test
    func getConfigSchemaRetriesOnceAfterUnauthorized() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config/schema", statusCode: 401, body: Data()),
            .init(path: "/api/config/schema", body: try loadFixtureData("config-schema.json")),
        ])
        let client = makeClient(http: http)

        let schema = try await client.getConfigSchema()

        #expect(schema.orderedKeys.isEmpty == false)
        #expect(http.recordedRequests.count == 2)
    }

    // MARK: - Helpers

    private struct ConfigUpdateProbe: Decodable {
        let config: JSONValue
    }

    private struct SoulUpdateProbe: Decodable {
        let content: String
    }

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
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
