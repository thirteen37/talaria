import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct ToolsMatrixHarnessTests {
    private static let statusJSON = Data(#"""
    {"version":"0.14.0","gateway_running":true,"gateway_platforms":{"telegram":{"state":"connected"},"slack":{"state":"connected"}}}
    """#.utf8)

    /// Two `web`-linked tool vars (one set, one unset) plus a provider var that
    /// belongs to no tool. Crucially the tool vars tag *function* names
    /// (`web_search` / `web_extract`), not the toolset id `web` — matching real
    /// Hermes — so resolving them to the `web` row requires the toolset map below.
    private static let envJSON = Data(#"""
    {
      "EXA_API_KEY": {"is_set":true,"redacted_value":"se…key","description":"Search key.","url":null,"category":"tool","is_password":true,"tools":["web_search","web_extract"],"advanced":false},
      "SEARXNG_URL": {"is_set":false,"redacted_value":null,"description":"Search URL.","url":null,"category":"tool","is_password":false,"tools":["web_search"],"advanced":false},
      "ANTHROPIC_API_KEY": {"is_set":true,"redacted_value":"sk-…wxyz","description":"API key.","url":null,"category":"provider","is_password":true,"tools":[],"advanced":false}
    }
    """#.utf8)

    /// `/api/tools/toolsets`: the `web` toolset's function names — the bridge that
    /// links the function-tagged env vars above to the `web` matrix row.
    private static let toolsetsJSON = Data(#"""
    [
      {"name":"web","label":"🔍 Web Search & Scraping","description":"web_search, web_extract","enabled":true,"available":true,"configured":true,"tools":["web_extract","web_search"]},
      {"name":"shell","label":"🐚 Shell","description":"shell","enabled":true,"available":true,"configured":true,"tools":["shell"]}
    ]
    """#.utf8)

    private static let okJSON = Data(#"{"ok":true}"#.utf8)

    @Test
    func refreshUsesCliPlusSortedGatewayPlatforms() async throws {
        let http = ToolsHTTPStub(responses: [
            .init(path: "/api/status", body: Self.statusJSON),
        ])
        let runner = ToolsRunner()
        let harness = ToolsMatrixHarness(client: makeClient(http), runner: runner)

        await harness.refresh()

        #expect(harness.matrix?.platforms == ["cli", "slack", "telegram"])
        #expect(harness.lastError == nil)
    }

    @Test
    func refreshFallsBackToCliWhenStatusFails() async throws {
        let http = ToolsHTTPStub(responses: [])
        let runner = ToolsRunner()
        let harness = ToolsMatrixHarness(client: makeClient(http), runner: runner)

        await harness.refresh()

        #expect(harness.matrix?.platforms == ["cli"])
        #expect(harness.lastError == nil)
    }

    @Test
    func toggleRunsScopedCommandThenRefreshes() async throws {
        let http = ToolsHTTPStub(responses: [
            .init(path: "/api/status", body: Self.statusJSON),
        ])
        let runner = ToolsRunner(stdoutByPlatform: [
            "cli": """
            Built-in toolsets (cli):
              ✓ enabled   web     🔍 Web Search & Scraping
            """,
            "slack": """
            Built-in toolsets (slack):
              ✓ enabled   web     🔍 Web Search & Scraping
            """,
            "telegram": """
            Built-in toolsets (telegram):
              ✗ disabled  web     🔍 Web Search & Scraping
            """,
        ])
        let harness = ToolsMatrixHarness(client: makeClient(http), runner: runner)

        await harness.setEnabled(tool: "web", platform: "slack", enabled: true)

        #expect(runner.received.first == ["tools", "enable", "--platform", "slack", "--", "web"])
        #expect(harness.matrix?.platforms == ["cli", "slack", "telegram"])
        let web = try #require(harness.matrix?.rows.first { $0.name == "web" })
        #expect(web.enabledByPlatform["slack"] == true)
        #expect(harness.lastError == nil)
    }

    @Test
    func configVarsResolveFunctionTaggedVarsToToolsetSetFirst() async throws {
        let http = ToolsHTTPStub(responses: [
            .init(path: "/api/status", body: Self.statusJSON),
            .init(path: "/api/env", body: Self.envJSON),
            .init(path: "/api/tools/toolsets", body: Self.toolsetsJSON),
        ])
        let harness = ToolsMatrixHarness(client: makeClient(http), runner: ToolsRunner())

        await harness.refresh()

        #expect(harness.envVars.count == 3)
        // Function-tagged vars resolve to the `web` toolset; set var first.
        #expect(harness.configVars(for: "web").map(\.name) == ["EXA_API_KEY", "SEARXNG_URL"])
        #expect(harness.hasConfig(for: "web"))
        // `shell` toolset exists but no env var references its function → no button.
        #expect(harness.configVars(for: "shell").isEmpty)
        #expect(!harness.hasConfig(for: "shell"))
        // The provider var (tools: []) leaks into no tool.
        #expect(!harness.hasConfig(for: "anthropic"))
    }

    @Test
    func configIsEmptyWithoutToolsetMapWhenVarsTagFunctionsNotIds() async throws {
        // Without `/api/tools/toolsets` (route unavailable), function-tagged vars
        // can't be resolved to the `web` id — the button correctly stays hidden
        // rather than guessing. (Regression for the original mapping bug.)
        let http = ToolsHTTPStub(responses: [
            .init(path: "/api/status", body: Self.statusJSON),
            .init(path: "/api/env", body: Self.envJSON),
        ])
        let harness = ToolsMatrixHarness(client: makeClient(http), runner: ToolsRunner())

        await harness.refresh()

        #expect(harness.envVars.count == 3)
        #expect(!harness.hasConfig(for: "web"))
    }

    @Test
    func saveEnvIssuesPutThenReloadsEnvWithoutRelistingMatrix() async throws {
        let http = ToolsHTTPStub(responses: [
            .init(path: "/api/status", body: Self.statusJSON),            // refresh
            .init(path: "/api/env", body: Self.envJSON),                  // refresh
            .init(path: "/api/tools/toolsets", body: Self.toolsetsJSON),  // refresh
            .init(path: "/api/env", body: Self.okJSON),                   // PUT
            .init(path: "/api/env", body: Self.envJSON),                  // env-only reload
        ])
        let runner = ToolsRunner()
        let harness = ToolsMatrixHarness(client: makeClient(http), runner: runner)

        await harness.refresh()
        let listCallsAfterRefresh = runner.received.count   // matrix fan-out so far
        harness.lastError = "previous failure"              // a successful save must clear this

        await harness.saveEnv(key: "EXA_API_KEY", value: "new-key")

        // The write went out as a PUT to /api/env...
        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/env"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["key"] as? String == "EXA_API_KEY")
        #expect(json["value"] as? String == "new-key")
        // ...and the matrix was NOT re-listed — no new CLI spawns after refresh.
        #expect(runner.received.count == listCallsAfterRefresh)
        #expect(harness.lastError == nil)
    }

    private func makeClient(_ http: ToolsHTTPStub) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

private final class ToolsRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutByPlatform: [String: String]
    private var _received: [[String]] = []

    init(stdoutByPlatform: [String: String] = [:]) {
        self.stdoutByPlatform = stdoutByPlatform
    }

    var received: [[String]] { lock.withLock { _received } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _received.append(command.arguments) }
        let platform = Self.platform(in: command.arguments)
        return HermesAdminResult(
            exitCode: 0,
            stdout: stdoutByPlatform[platform] ?? "",
            stderr: ""
        )
    }

    private static func platform(in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--platform"),
              arguments.indices.contains(index + 1) else {
            return "unscoped"
        }
        return arguments[index + 1]
    }
}

private final class ToolsHTTPStub: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "ToolsHTTPStub")
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
