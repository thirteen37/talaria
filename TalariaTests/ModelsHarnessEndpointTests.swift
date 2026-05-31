import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct ModelsHarnessEndpointTests {
    @Test
    func revealReturnsValueFromEnvRevealRoute() async throws {
        let http = StatusStubHTTP(responses: [
            .init(
                path: "/api/env/reveal",
                body: Data(#"{"key":"HERMES_CUSTOM_MY_LLM_API_KEY","value":"sk-secret"}"#.utf8)
            )
        ])
        let harness = ModelsHarness(client: makeClient(http))

        let value = try await harness.revealEndpointKey(slug: "my-llm")

        #expect(value == "sk-secret")
        #expect(harness.lastError == nil)
    }

    @Test
    func revealFallsBackToExpandedConfigOn404() async throws {
        // Key stored under a non-derived name → reveal 404s → fall back to the
        // expanded api_key from config (here a real, resolved secret).
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 404, body: Data(#"{"detail":"not found"}"#.utf8)),
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"api_key":"sk-from-config"}}}
            """#.utf8)),
        ])
        let harness = ModelsHarness(client: makeClient(http))

        let value = try await harness.revealEndpointKey(slug: "my-llm")

        #expect(value == "sk-from-config")
    }

    @Test
    func revealReturnsNilWhenConfigHoldsOnlyUnresolvedTemplate() async throws {
        // 404 + config api_key is a bare ${VAR} (referenced var unset) → nothing
        // to reveal, but this is not an error.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 404, body: Data()),
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"api_key":"${HERMES_CUSTOM_MY_LLM_API_KEY}"}}}
            """#.utf8)),
        ])
        let harness = ModelsHarness(client: makeClient(http))

        let value = try await harness.revealEndpointKey(slug: "my-llm")

        #expect(value == nil)
    }

    @Test
    func revealThrowsOnTransientErrorInsteadOfLookingLikeClearedKey() async throws {
        // A 500 must surface to the caller — not be swallowed into an empty
        // field that's indistinguishable from "no key configured".
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        ])
        let harness = ModelsHarness(client: makeClient(http))

        await #expect(throws: DashboardClientError.self) {
            _ = try await harness.revealEndpointKey(slug: "my-llm")
        }
    }

    @Test
    func saveNewEndpointDeDupesSlugAgainstFreshConfigNotStaleMemory() async throws {
        // A provider added by another window/hand-edit is present in the freshly
        // fetched config but absent from the (never-refreshed) in-memory list.
        // The derived slug must de-dup against the fresh config so the existing
        // provider isn't overwritten in place.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"name":"Existing","base_url":"https://old/v1"}}}
            """#.utf8)),                                   // GET for slug + merge
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),         // PUT
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                    // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let newEndpoint = CustomEndpoint(
            slug: "",
            name: "My LLM",            // slugifies to "my-llm" → collides
            baseURL: "https://new/v1",
            models: [],
            defaultModel: nil,
            discoverModels: true,
            hasAPIKey: false
        )

        await harness.saveEndpoint(newEndpoint, newKey: nil)

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try #require((json["config"] as? [String: Any])?["providers"] as? [String: Any])
        // Existing provider survives untouched; the new one lands under -2.
        #expect((providers["my-llm"] as? [String: Any])?["name"] as? String == "Existing")
        let added = try #require(providers["my-llm-2"] as? [String: Any])
        #expect(added["name"] as? String == "My LLM")
        #expect(added["base_url"] as? String == "https://new/v1")
    }

    @Test
    func saveReportsFailureAndDoesNotWriteKeyWhenConfigFetchFails() async throws {
        // The pre-merge getConfig fails → save reports failure (so the form can
        // keep the sheet + typed input open) and never writes the secret.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false
        )

        let ok = await harness.saveEndpoint(endpoint, newKey: "sk-typed")

        #expect(ok == false)
        #expect(harness.lastError != nil)
        #expect(!http.recordedRequests.contains { $0.url?.path == "/api/env" })
    }

    @Test
    func saveReportsSuccessOnCompletedRoundTrip() async throws {
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"{"providers":{}}"#.utf8)),     // GET (slug + merge)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),          // PUT
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                     // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false
        )

        let ok = await harness.saveEndpoint(endpoint, newKey: nil)

        #expect(ok == true)
        #expect(harness.lastError == nil)
    }

    @Test
    func removeToleratesNon404EnvDeleteAndStillRefreshes() async throws {
        // The config removal (the meaningful action) succeeds; a transient 5xx
        // from the best-effort .env cleanup must not strand the removed provider
        // in the list — removal drives the success/refresh path regardless.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"name":"My LLM"}}}
            """#.utf8)),                                                   // GET (fresh)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT (remove)
            .init(path: "/api/env", statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8)), // DELETE
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))

        await harness.removeEndpoint(slug: "my-llm")

        #expect(harness.lastError == nil)
        // refresh() ran (it fetches options) — proving the success path drove it.
        #expect(http.recordedRequests.contains { $0.url?.path == "/api/model/options" })
    }

    private func makeClient(_ http: StatusStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Stub that returns arbitrary status codes and serves responses by **matching
/// path** (in queue order among same-path entries), so `refresh()`'s concurrent
/// GETs resolve deterministically. Records requests for body assertions.
private final class StatusStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "StatusStubHTTP")
    private var responses: [Response]
    private var _recordedRequests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var recordedRequests: [URLRequest] { queue.sync { _recordedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let match: Response? = queue.sync {
            _recordedRequests.append(request)
            guard let index = responses.firstIndex(where: { $0.path == request.url?.path }) else {
                return nil
            }
            return responses.remove(at: index)
        }
        guard let url = request.url, let match else {
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
