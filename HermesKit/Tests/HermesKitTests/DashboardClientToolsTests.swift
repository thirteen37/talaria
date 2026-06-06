import Foundation
import Testing
@testable import HermesKit

/// Decode + request-shape tests for the three desktop-parity REST routes
/// (`/api/model/info`, `/api/config/defaults`, `/api/tools/toolsets`) and the
/// toolset toggle (`PUT /api/tools/toolsets/{name}`). Golden JSON → Codable,
/// mirroring `DashboardClientTests`.
@Suite
struct DashboardClientToolsTests {
    private func makeClient(_ http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { nil },
            http: http
        )
    }

    // MARK: - /api/model/info

    @Test
    func getModelInfoDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/model/info", body: try loadFixtureData("model-info.json"))
        ])
        let info = try await makeClient(http).getModelInfo()

        #expect(info.model == "claude-sonnet-4.6")
        #expect(info.provider == "anthropic")
        #expect(info.autoContextLength == 200000)
        #expect(info.configContextLength == 0)
        #expect(info.effectiveContextLength == 200000)
        #expect(info.capabilities?.supportsTools == true)
        #expect(info.capabilities?.supportsVision == true)
        #expect(info.capabilities?.supportsReasoning == true)
        #expect(info.capabilities?.contextWindow == 200000)
        #expect(info.capabilities?.maxOutputTokens == 16000)
        #expect(info.capabilities?.modelFamily == "claude")
    }

    @Test
    func getModelInfoToleratesEmptyCapabilities() async throws {
        // The server returns `capabilities: {}` when model metadata can't be
        // resolved — every capability field is optional, so it must still decode.
        let http = StubHTTP(responses: [
            .init(path: "/api/model/info", body: try loadFixtureData("model-info-empty.json"))
        ])
        let info = try await makeClient(http).getModelInfo()

        #expect(info.model == "")
        #expect(info.provider == "")
        #expect(info.effectiveContextLength == 0)
        let caps = try #require(info.capabilities)
        #expect(caps.supportsTools == nil)
        #expect(caps.modelFamily == nil)
    }

    // MARK: - /api/config/defaults

    @Test
    func getConfigDefaultsDecodesAsJSONValue() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/config/defaults", body: try loadFixtureData("config-defaults.json"))
        ])
        let defaults = try await makeClient(http).getConfigDefaults()

        // Returned verbatim as JSONValue so arbitrary keys round-trip (same
        // contract as getConfig).
        guard case let .object(root) = defaults else {
            Issue.record("expected a JSON object")
            return
        }
        #expect(root["model"] == .string(""))
        #expect(root["toolsets"] == .array([.string("hermes-cli")]))
        guard case let .object(agent)? = root["agent"] else {
            Issue.record("expected agent object")
            return
        }
        #expect(agent["max_turns"] == .number(90))
    }

    // MARK: - /api/tools/toolsets

    @Test
    func getToolsetsDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/tools/toolsets", body: try loadFixtureData("tools-toolsets.json"))
        ])
        let toolsets = try await makeClient(http).getToolsets()

        #expect(toolsets.count == 27)
        let web = try #require(toolsets.first)
        #expect(web.name == "web")
        #expect(web.label == "🔍 Web Search & Scraping")
        #expect(web.enabled == true)
        #expect(web.available == true)
        #expect(web.configured == true)
        #expect(web.tools == ["web_extract", "web_search"])

        let vision = try #require(toolsets.first { $0.name == "vision" })
        #expect(vision.enabled == false)
        #expect(vision.available == false)
    }

    @Test
    func setToolsetSendsPutWithEnabledBodyAndDecodesResult() async throws {
        let http = StubHTTP(responses: [
            .init(
                path: "/api/tools/toolsets/web",
                body: Data(#"{"ok":true,"name":"web","enabled":false}"#.utf8)
            )
        ])
        let result = try await makeClient(http).setToolset(name: "web", enabled: false)

        #expect(result.ok == true)
        #expect(result.name == "web")
        #expect(result.enabled == false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/api/tools/toolsets/web")
        let bodyData = try #require(request.httpBody)
        let bodyJSON = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyJSON?["enabled"] as? Bool == false)
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
