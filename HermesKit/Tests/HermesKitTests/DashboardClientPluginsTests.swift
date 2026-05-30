import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientPluginsTests {
    @Test
    func getPluginsHubDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/plugins/hub", body: try loadFixtureData("plugins-hub.json"))
        ])
        let client = makeClient(http: http)

        let hub = try await client.getPluginsHub()

        #expect(hub.plugins.count == 2)
        let browser = try #require(hub.plugins.first { $0.name == "browser/browser_use" })
        #expect(browser.source == "bundled")
        #expect(browser.runtimeStatus == "inactive")
        #expect(browser.hasDashboardManifest == false)
        #expect(browser.canRemove == false)
        #expect(browser.canUpdateGit == false)
        #expect(browser.authRequired == false)

        let linear = try #require(hub.plugins.first { $0.name == "linear" })
        #expect(linear.source == "git")
        #expect(linear.runtimeStatus == "enabled")
        #expect(linear.canRemove == true)
        #expect(linear.canUpdateGit == true)
        #expect(linear.authRequired == true)
        #expect(linear.authCommand == "hermes plugin auth linear")

        #expect(hub.providers.memoryProvider == "hindsight")
        #expect(hub.providers.contextEngine == "compressor")
        #expect(hub.providers.memoryOptions.map(\.name) == ["hindsight", "sqlite"])
        #expect(hub.providers.contextOptions.map(\.name) == ["compressor", "passthrough"])
    }

    @Test
    func installPluginPostsIdentifierForceAndEnable() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/agent-plugins/install", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.installPlugin(identifier: "owner/repo", force: true, enable: false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/dashboard/agent-plugins/install")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["identifier"]?.stringValue == "owner/repo")
        #expect(json["force"]?.boolValue == true)
        #expect(json["enable"]?.boolValue == false)
    }

    @Test
    func installPluginParsesNameWarningsAndMissingEnv() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/dashboard/agent-plugins/install",
                body: Data(#"""
                {"ok":true,"plugin_name":"linear","warnings":["Insecure URL scheme."],"missing_env":["LINEAR_API_KEY"],"enabled":true}
                """#.utf8)
            )
        ])
        let client = makeClient(http: http)

        let result = try await client.installPlugin(identifier: "owner/linear", force: false, enable: true)

        #expect(result.ok == true)
        #expect(result.pluginName == "linear")
        #expect(result.enabled == true)
        #expect(result.warnings == ["Insecure URL scheme."])
        #expect(result.missingEnv == ["LINEAR_API_KEY"])
    }

    @Test
    func installPluginToleratesEmptyResponseBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/agent-plugins/install", body: Data())
        ])
        let client = makeClient(http: http)

        let result = try await client.installPlugin(identifier: "owner/repo", force: false, enable: true)

        #expect(result.pluginName == nil)
        #expect(result.warnings.isEmpty)
        #expect(result.missingEnv.isEmpty)
    }

    @Test
    func setPluginEnabledPostsToEnableSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/agent-plugins/linear/enable", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.setPluginEnabled(name: "linear", enabled: true)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/dashboard/agent-plugins/linear/enable")
    }

    @Test
    func setPluginEnabledPostsToDisableSubpathForSlashedName() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/agent-plugins/browser/browser_use/disable", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.setPluginEnabled(name: "browser/browser_use", enabled: false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/dashboard/agent-plugins/browser/browser_use/disable")
    }

    @Test
    func updatePluginPostsToUpdateSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/agent-plugins/linear/update", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.updatePlugin(name: "linear")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/dashboard/agent-plugins/linear/update")
    }

    @Test
    func removePluginIssuesDeleteToScopedPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/agent-plugins/linear", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.removePlugin(name: "linear")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/dashboard/agent-plugins/linear")
    }

    @Test
    func setPluginProvidersPutsMemoryAndContext() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/plugin-providers", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.setPluginProviders(memoryProvider: "sqlite", contextEngine: "passthrough")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/dashboard/plugin-providers")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["memory_provider"]?.stringValue == "sqlite")
        #expect(json["context_engine"]?.stringValue == "passthrough")
    }

    @Test
    func setPluginProvidersSendsEmptyStringForBuiltInMemory() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/dashboard/plugin-providers", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.setPluginProviders(memoryProvider: "", contextEngine: nil)

        let request = try #require(http.recordedRequests.first)
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        // Empty string means "built-in / none" and must be sent explicitly.
        #expect(json["memory_provider"]?.stringValue == "")
        // A nil context engine is omitted entirely rather than sent as null.
        #expect(json["context_engine"] == nil)
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
