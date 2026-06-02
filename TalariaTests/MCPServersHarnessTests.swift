import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the delete+re-add "Edit" round-trip in ``MCPServersHarness`` — the
/// non-atomic path where the compensation behavior matters (refresh on failure,
/// arg round-tripping, re-applied disabled state).
@MainActor
@Suite
struct MCPServersHarnessTests {
    /// A disabled stdio server whose argv contains a space — exercises both the
    /// arg-round-trip and the re-apply-disabled fixes.
    private static func serverListJSON(enabled: Bool) -> Data {
        Data(#"""
        {"servers":[{"name":"fs","transport":"stdio","url":null,"command":"npx","args":["--root","/My Files/docs"],"env":{},"auth":null,"enabled":\#(enabled),"tools":null}]}
        """#.utf8)
    }

    private static let addResponseJSON = Data(#"""
    {"name":"fs","transport":"stdio","command":"npx","args":["--root","/My Files/docs"],"env":{},"auth":null,"enabled":true,"tools":null}
    """#.utf8)

    @Test
    func editFailureAfterDeleteRefreshesAndKeepsDraft() async throws {
        let http = MCPStubHTTP(responses: [
            .init(path: "/api/mcp/servers", body: Self.serverListJSON(enabled: true)),  // initial refresh
            .init(path: "/api/mcp/servers/fs", body: Data(#"{"ok":true}"#.utf8)),        // DELETE succeeds
            .init(path: "/api/mcp/servers", statusCode: 400, body: Data(#"{"detail":"bad"}"#.utf8)), // POST add fails
            .init(path: "/api/mcp/servers", body: Data(#"{"servers":[]}"#.utf8)),        // catch → refresh
        ])
        let harness = MCPServersHarness(client: makeClient(http))
        await harness.refresh()
        let server = try #require(harness.servers.first)
        harness.beginEdit(server)

        await harness.commit(try #require(harness.draft))

        // Delete landed but re-add failed: the error is surfaced, the editing
        // marker is cleared (so a retry won't re-delete a now-missing server),
        // the draft stays open to retry, and the table reflects the deletion.
        #expect(harness.lastError != nil)
        #expect(harness.editingServer == nil)
        #expect(harness.draft != nil)
        #expect(harness.servers.isEmpty)
        // A refresh GET ran on the failure path (2 total: initial + catch).
        let gets = http.recordedRequests.filter {
            $0.httpMethod == "GET" && $0.url?.path == "/api/mcp/servers"
        }
        #expect(gets.count == 2)
    }

    @Test
    func editReappliesDisabledStateAndRoundTripsArgsWithSpaces() async throws {
        let http = MCPStubHTTP(responses: [
            .init(path: "/api/mcp/servers", body: Self.serverListJSON(enabled: false)), // initial refresh
            .init(path: "/api/mcp/servers/fs", body: Data(#"{"ok":true}"#.utf8)),         // DELETE
            .init(path: "/api/mcp/servers", body: Self.addResponseJSON),                  // POST add
            .init(path: "/api/mcp/servers/fs/enabled", body: Data(#"{"ok":true}"#.utf8)), // re-apply disabled
            .init(path: "/api/mcp/servers", body: Data(#"{"servers":[]}"#.utf8)),         // success refresh
        ])
        let harness = MCPServersHarness(client: makeClient(http))
        await harness.refresh()
        let server = try #require(harness.servers.first)
        harness.beginEdit(server)

        await harness.commit(try #require(harness.draft))

        #expect(harness.lastError == nil)
        #expect(harness.draft == nil)

        // The re-add preserved the space-containing argument verbatim.
        let post = try #require(http.recordedRequests.first {
            $0.httpMethod == "POST" && $0.url?.path == "/api/mcp/servers"
        })
        let body = try #require(post.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["args"] as? [String] == ["--root", "/My Files/docs"])

        // The prior disabled state was re-applied (a re-added server is enabled
        // by default).
        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/mcp/servers/fs/enabled"
        })
        let putBody = try #require(put.httpBody)
        let putJSON = try #require(try JSONSerialization.jsonObject(with: putBody) as? [String: Any])
        #expect(putJSON["enabled"] as? Bool == false)
    }

    @Test
    func backgroundCatalogInstallPollsActionBeforeRefreshing() async throws {
        let http = MCPStubHTTP(responses: [
            // Git-bootstrap install returns immediately, detached.
            .init(path: "/api/mcp/catalog/install",
                  body: Data(#"{"ok":true,"name":"gitmcp","background":true,"action":"mcp-install"}"#.utf8)),
            // Action already finished on first poll (no test sleep).
            .init(path: "/api/actions/mcp-install/status",
                  body: Data(#"{"name":"mcp-install","running":false,"exit_code":0,"pid":1,"lines":[]}"#.utf8)),
            // Post-install refresh + catalog reload.
            .init(path: "/api/mcp/servers", body: Data(#"{"servers":[]}"#.utf8)),
            .init(path: "/api/mcp/catalog", body: Data(#"{"entries":[],"diagnostics":[]}"#.utf8)),
        ])
        let harness = MCPServersHarness(client: makeClient(http))
        let entry = DashboardMCPCatalogEntry(name: "gitmcp", needsInstall: true)

        await harness.install(entry: entry, env: [:])

        // The detached action was polled before the refresh fired.
        #expect(http.recordedRequests.contains {
            $0.httpMethod == "GET" && $0.url?.path == "/api/actions/mcp-install/status"
        })
        #expect(harness.lastError == nil)
        #expect(harness.installing.contains("gitmcp") == false)
    }

    @Test
    func backgroundInstallFailureSurfacesError() async throws {
        let http = MCPStubHTTP(responses: [
            .init(path: "/api/mcp/catalog/install",
                  body: Data(#"{"ok":true,"name":"gitmcp","background":true,"action":"mcp-install"}"#.utf8)),
            // Detached clone finished but failed (non-zero exit).
            .init(path: "/api/actions/mcp-install/status",
                  body: Data(#"{"name":"mcp-install","running":false,"exit_code":1,"pid":1,"lines":["fatal: repo not found"]}"#.utf8)),
            .init(path: "/api/mcp/servers", body: Data(#"{"servers":[]}"#.utf8)),
            .init(path: "/api/mcp/catalog", body: Data(#"{"entries":[],"diagnostics":[]}"#.utf8)),
        ])
        let harness = MCPServersHarness(client: makeClient(http))

        await harness.install(entry: DashboardMCPCatalogEntry(name: "gitmcp", needsInstall: true), env: [:])

        // The failure survives the post-install refresh/loadCatalog (which clear
        // lastError on success) instead of reading as a silent success.
        let error = try #require(harness.lastError)
        #expect(error.contains("failed"))
        #expect(harness.installing.contains("gitmcp") == false)
    }

    @Test
    func synchronousInstallFailureSurfacesError() async throws {
        let http = MCPStubHTTP(responses: [
            // 200 but in-band failure (no background action).
            .init(path: "/api/mcp/catalog/install",
                  body: Data(#"{"ok":false,"name":"sync","background":false}"#.utf8)),
            .init(path: "/api/mcp/servers", body: Data(#"{"servers":[]}"#.utf8)),
            .init(path: "/api/mcp/catalog", body: Data(#"{"entries":[],"diagnostics":[]}"#.utf8)),
        ])
        let harness = MCPServersHarness(client: makeClient(http))

        await harness.install(entry: DashboardMCPCatalogEntry(name: "sync"), env: [:])

        let error = try #require(harness.lastError)
        #expect(error.contains("failed"))
    }

    // MARK: - Helpers

    private func makeClient(_ http: MCPStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Path-matching HTTP stub (serves same-path responses in queue order, with
/// per-response status codes) so a multi-call edit round-trip resolves
/// deterministically.
private final class MCPStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "MCPStubHTTP")
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
