import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientProfilesTests {
    @Test
    func listProfilesDecodesNamesAndDefaultFlag() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles", body: try loadFixtureData("profiles.json"))
        ])
        let client = makeClient(http: http)

        let profiles = try await client.listProfiles()

        // Clean names straight from the dashboard — no CLI table markers.
        #expect(profiles.map(\.name) == ["default", "dev", "dining"])
        let first = try #require(profiles.first)
        #expect(first.isDefault == true)
        #expect(first.model == "anthropic/claude-sonnet-4.6")
        // Only the default is flagged.
        #expect(profiles.filter(\.isDefault).map(\.name) == ["default"])
    }

    @Test
    func listProfilesToleratesMissingAndNullOptionalFields() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles", body: try loadFixtureData("profiles.json"))
        ])
        let client = makeClient(http: http)

        let profiles = try await client.listProfiles()

        let dev = try #require(profiles.first { $0.name == "dev" })
        #expect(dev.model == nil)
        let dining = try #require(profiles.first { $0.name == "dining" })
        #expect(dining.isDefault == false)
        #expect(dining.model == nil)
    }

    @Test
    func listProfilesSendsTokenAndHitsProfilesPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles", body: try loadFixtureData("profiles.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.listProfiles()

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/profiles")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "tok")
    }

    // MARK: - Selector loading (window switcher source-of-truth behavior)

    @Test
    func selectorProfilesStaysDefaultOnlyWithoutClient() async {
        // Dashboard not online yet: the switcher stays default-only (hidden), and
        // there is no CLI fallback path to leak decorated names.
        let profiles = await HermesProfiles.selectorProfiles(client: nil)

        #expect(profiles.map(\.name) == ["default"])
        #expect(profiles.first?.isDefault == true)
    }

    @Test
    func selectorProfilesUsesDashboardNamesExactly() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles", body: try loadFixtureData("profiles.json"))
        ])
        let client = makeClient(http: http)

        let profiles = await HermesProfiles.selectorProfiles(client: client)

        // Exact dashboard names, including a clean `default` — no `◆default`.
        #expect(profiles.map(\.name) == ["default", "dev", "dining"])
        #expect(profiles.filter(\.isDefault).map(\.name) == ["default"])
    }

    @Test
    func selectorProfilesStaysDefaultOnlyOnAPIFailure() async {
        // API failure must not fall back to CLI-parsed names: stay default-only.
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles", statusCode: 500, body: Data("boom".utf8))
        ])
        let client = makeClient(http: http)

        let profiles = await HermesProfiles.selectorProfiles(client: client)

        #expect(profiles.map(\.name) == ["default"])
        #expect(profiles.first?.isDefault == true)
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
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Dashboard")
        )
        return try Data(contentsOf: url)
    }
}
