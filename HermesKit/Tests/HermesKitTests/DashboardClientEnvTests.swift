import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientEnvTests {
    @Test
    func setEnvVarPutsKeyAndValue() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.setEnvVar(key: "HERMES_CUSTOM_MY_LLM_API_KEY", value: "sk-secret")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/env")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["key"]?.stringValue == "HERMES_CUSTOM_MY_LLM_API_KEY")
        #expect(json["value"]?.stringValue == "sk-secret")
    }

    @Test
    func deleteEnvVarIssuesDeleteWithKey() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.deleteEnvVar(key: "HERMES_CUSTOM_MY_LLM_API_KEY")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/env")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["key"]?.stringValue == "HERMES_CUSTOM_MY_LLM_API_KEY")
    }

    @Test
    func deleteEnvVarToleratesNotFound() async throws {
        // A custom key may already be gone (hand-edited .env). Deleting it must
        // not surface a 404 to the caller — the desired end-state is reached.
        let http = StubHTTP(responses: [
            .init(path: "/api/env", statusCode: 404, body: Data(#"{"detail":"not found"}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.deleteEnvVar(key: "HERMES_CUSTOM_GONE_API_KEY")

        #expect(http.recordedRequests.count == 1)
    }

    @Test
    func revealEnvVarPostsKeyAndReturnsValue() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env/reveal", body: Data(#"{"value":"sk-secret"}"#.utf8))
        ])
        let client = makeClient(http: http)

        let value = try await client.revealEnvVar(key: "HERMES_CUSTOM_MY_LLM_API_KEY")

        #expect(value == "sk-secret")
        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/env/reveal")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["key"]?.stringValue == "HERMES_CUSTOM_MY_LLM_API_KEY")
    }

    @Test
    func revealEnvVarSurfacesNotFound() async throws {
        // A key stored under a non-derived name (hand-edited config) 404s; the
        // caller falls back to the expanded config value, so the error must
        // reach it rather than being swallowed.
        let http = StubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 404, body: Data(#"{"detail":"not found"}"#.utf8))
        ])
        let client = makeClient(http: http)

        await #expect(throws: DashboardClientError.self) {
            _ = try await client.revealEnvVar(key: "HERMES_CUSTOM_MISSING_API_KEY")
        }
    }

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}
