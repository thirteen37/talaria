import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientMCPTests {
    // MARK: - Servers

    @Test
    func listMCPServersDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/servers", body: try loadFixtureData("mcp-servers.json"))
        ])
        let client = makeClient(http: http)

        let servers = try await client.listMCPServers()

        #expect(servers.count == 2)
        let fs = try #require(servers.first { $0.name == "filesystem" })
        #expect(fs.transport == "stdio")
        #expect(fs.command == "npx")
        #expect(fs.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        #expect(fs.env?["FS_TOKEN"] == "sk-…4f9a")   // redacted server-side
        #expect(fs.enabled == true)
        #expect(fs.tools == nil)

        let linear = try #require(servers.first { $0.name == "linear" })
        #expect(linear.transport == "http")
        #expect(linear.url == "https://mcp.linear.app/sse")
        #expect(linear.auth == "oauth")
        #expect(linear.enabled == false)
        #expect(linear.tools == ["list_issues", "create_issue"])
    }

    @Test
    func addMCPServerStdioPostsBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/servers", body: try loadFixtureData("mcp-add-response.json"))
        ])
        let client = makeClient(http: http)

        let created = try await client.addMCPServer(
            name: "filesystem",
            command: "npx",
            args: ["-y", "server-filesystem"],
            env: ["FS_TOKEN": "secret"]
        )
        #expect(created.name == "filesystem")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mcp/servers")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "filesystem")
        #expect(json["command"] as? String == "npx")
        #expect(json["args"] as? [String] == ["-y", "server-filesystem"])
        #expect((json["env"] as? [String: String])?["FS_TOKEN"] == "secret")
        // url omitted when nil (synthesized encodeIfPresent).
        #expect(json["url"] == nil)
    }

    @Test
    func addMCPServerHttpPostsBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/servers", body: try loadFixtureData("mcp-add-response.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.addMCPServer(
            name: "linear",
            url: "https://mcp.linear.app/sse",
            auth: "oauth"
        )

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "linear")
        #expect(json["url"] as? String == "https://mcp.linear.app/sse")
        #expect(json["auth"] as? String == "oauth")
        // command omitted for a remote server.
        #expect(json["command"] == nil)
    }

    @Test
    func testMCPServerPostsToTestSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/servers/filesystem/test", body: try loadFixtureData("mcp-test-result.json"))
        ])
        let client = makeClient(http: http)

        let result = try await client.testMCPServer(name: "filesystem")

        #expect(result.ok == true)
        #expect(result.tools.count == 2)
        #expect(result.tools.first?.name == "read_file")
        #expect(result.tools.first?.description == "Read a file from disk")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mcp/servers/filesystem/test")
    }

    @Test
    func setMCPServerEnabledPutsBool() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/servers/filesystem/enabled", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.setMCPServerEnabled(name: "filesystem", enabled: false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/mcp/servers/filesystem/enabled")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(decoded["enabled"]?.boolValue == false)
    }

    @Test
    func deleteMCPServerIssuesDeleteToScopedPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/servers/filesystem", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.deleteMCPServer(name: "filesystem")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/mcp/servers/filesystem")
    }

    // MARK: - Catalog

    @Test
    func listMCPCatalogDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/catalog", body: try loadFixtureData("mcp-catalog.json"))
        ])
        let client = makeClient(http: http)

        let entries = try await client.listMCPCatalog()

        #expect(entries.count == 2)
        let github = try #require(entries.first { $0.name == "github" })
        #expect(github.transport == "http")
        #expect(github.authType == "oauth")
        #expect(github.requiredEnv?.isEmpty == true)
        #expect(github.needsInstall == false)

        let brave = try #require(entries.first { $0.name == "brave-search" })
        #expect(brave.needsInstall == true)
        let env = try #require(brave.requiredEnv?.first)
        #expect(env.name == "BRAVE_API_KEY")
        #expect(env.prompt == "Brave Search API key")
        #expect(env.required == true)
    }

    @Test
    func installMCPCatalogEntryPostsEnv() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/mcp/catalog/install", body: Data(#"{"ok":true,"name":"brave-search","background":false}"#.utf8))
        ])
        let client = makeClient(http: http)

        let result = try await client.installMCPCatalogEntry(
            name: "brave-search",
            env: ["BRAVE_API_KEY": "abc123"]
        )
        #expect(result.ok == true)
        #expect(result.background == false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/mcp/catalog/install")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "brave-search")
        #expect((json["env"] as? [String: String])?["BRAVE_API_KEY"] == "abc123")
        #expect(json["enable"] as? Bool == true)
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
