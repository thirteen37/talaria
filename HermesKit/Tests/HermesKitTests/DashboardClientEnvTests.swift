import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientEnvTests {
    @Test
    func listEnvVarsDecodesDictAndSortsByCategoryThenName() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env", body: try loadFixtureData("env.json"))
        ])
        let client = makeClient(http: http)

        let vars = try await client.listEnvVars()

        // Sorted by (category-rank, name): provider, messaging, setting.
        #expect(vars.map(\.name) == ["ANTHROPIC_API_KEY", "TELEGRAM_BOT_TOKEN", "HERMES_LOG_LEVEL"])

        let anthropic = try #require(vars.first { $0.name == "ANTHROPIC_API_KEY" })
        #expect(anthropic.isSet == false)
        #expect(anthropic.redactedValue == nil)
        #expect(anthropic.category == "provider")
        #expect(anthropic.isPassword == true)
        #expect(anthropic.tools.isEmpty)
        #expect(anthropic.advanced == false)

        let telegram = try #require(vars.first { $0.name == "TELEGRAM_BOT_TOKEN" })
        #expect(telegram.isSet == true)
        #expect(telegram.redactedValue == "12345…wxyz")
        #expect(telegram.category == "messaging")
        #expect(telegram.isPassword == true)
        #expect(telegram.tools == ["telegram"])

        let logLevel = try #require(vars.first { $0.name == "HERMES_LOG_LEVEL" })
        #expect(logLevel.isPassword == false)
        #expect(logLevel.advanced == true)
        #expect(logLevel.url == nil)
    }

    @Test
    func setEnvVarPutsKeyAndValue() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env", body: Data(#"{"ok":true,"key":"ANTHROPIC_API_KEY"}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.setEnvVar(key: "ANTHROPIC_API_KEY", value: "sk-secret")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/env")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["key"]?.stringValue == "ANTHROPIC_API_KEY")
        #expect(json["value"]?.stringValue == "sk-secret")
    }

    @Test
    func deleteEnvVarDeletesKey() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env", body: Data(#"{"ok":true,"key":"ANTHROPIC_API_KEY"}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.deleteEnvVar(key: "ANTHROPIC_API_KEY")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/env")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["key"]?.stringValue == "ANTHROPIC_API_KEY")
    }

    @Test
    func deleteEnvVarThrowsHTTPOnMissingKey() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/env",
                statusCode: 404,
                body: Data(#"{"detail":"ANTHROPIC_API_KEY not found in .env"}"#.utf8)
            )
        ])
        let client = makeClient(http: http)

        await #expect(throws: DashboardClientError.self) {
            try await client.deleteEnvVar(key: "ANTHROPIC_API_KEY")
        }
    }

    @Test
    func revealEnvVarPostsKeyAndReturnsValue() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/env/reveal",
                body: Data(#"{"key":"ANTHROPIC_API_KEY","value":"sk-real-secret"}"#.utf8)
            )
        ])
        let client = makeClient(http: http)

        let value = try await client.revealEnvVar(key: "ANTHROPIC_API_KEY")

        #expect(value == "sk-real-secret")
        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/env/reveal")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["key"]?.stringValue == "ANTHROPIC_API_KEY")
    }

    @Test
    func revealEnvVarThrowsHTTPWhenRateLimited() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/env/reveal",
                statusCode: 429,
                body: Data(#"{"detail":"Too many reveal requests. Try again shortly."}"#.utf8)
            )
        ])
        let client = makeClient(http: http)

        await #expect(throws: DashboardClientError.self) {
            _ = try await client.revealEnvVar(key: "ANTHROPIC_API_KEY")
        }
    }

    // MARK: - Helpers

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }

    private func loadFixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Dashboard")
        )
        return try Data(contentsOf: url)
    }
}
