import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct GatewayHarnessTests {
    /// Telegram (token + allowed users) plus a non-messaging var that must not
    /// leak into any card.
    private static let envJSON = Data(#"""
    {
      "TELEGRAM_BOT_TOKEN": {"is_set":true,"redacted_value":"12345…wxyz","description":"Bot token.","url":"https://t.me/BotFather","category":"messaging","is_password":true,"tools":["telegram"],"advanced":false},
      "TELEGRAM_ALLOWED_USERS": {"is_set":false,"redacted_value":null,"description":"Allowed users.","url":null,"category":"messaging","is_password":false,"tools":[],"advanced":false},
      "ANTHROPIC_API_KEY": {"is_set":false,"redacted_value":null,"description":"API key.","url":null,"category":"provider","is_password":true,"tools":[],"advanced":false}
    }
    """#.utf8)

    private static let statusJSON = Data(#"""
    {"version":"0.14.0","gateway_running":true,"gateway_platforms":{"telegram":{"state":"connected"}}}
    """#.utf8)

    /// Telegram (covered by a messaging group) plus Signal — gateway-reported
    /// but config.yaml-only, with no messaging env var — so Signal must surface
    /// as a status-only row rather than an editable group.
    private static let statusWithStatusOnlyJSON = Data(#"""
    {"version":"0.14.0","gateway_running":true,"gateway_platforms":{"telegram":{"state":"connected"},"signal":{"state":"error","error_message":"not linked"}}}
    """#.utf8)

    /// Home Assistant env var (HASS_*) plus the gateway-reported `homeassistant`
    /// platform — the curated catalog entry must collapse these into one card,
    /// never an editable "Hass" group beside a status-only "homeassistant" row.
    private static let envHassJSON = Data(#"""
    {
      "HASS_TOKEN": {"is_set":true,"redacted_value":"abc…xyz","description":"Long-lived token.","url":null,"category":"messaging","is_password":true,"tools":["homeassistant"],"advanced":false}
    }
    """#.utf8)

    private static let statusHassJSON = Data(#"""
    {"version":"0.14.0","gateway_running":true,"gateway_platforms":{"homeassistant":{"state":"connected"}}}
    """#.utf8)

    private static let okJSON = Data(#"{"ok":true}"#.utf8)

    @Test
    func refreshPopulatesGroupsAndWiresConnection() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envJSON),
            .init(path: "/api/status", body: Self.statusJSON),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.refresh()

        let telegram = try #require(harness.groups.first { $0.id == "telegram" })
        #expect(telegram.fields.map(\.envVar.name) == ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS"])
        #expect(telegram.connection?.state == "connected")
        // Non-messaging vars never produce a card.
        #expect(harness.groups.allSatisfy { $0.id != "anthropic" })
        #expect(harness.lastError == nil)
    }

    @Test
    func refreshToleratesStatusFailure() async throws {
        // No /api/status response queued → the status fetch fails, but the
        // cards still render with nil connections.
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envJSON),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.refresh()

        #expect(harness.status == nil)
        let telegram = try #require(harness.groups.first { $0.id == "telegram" })
        #expect(telegram.connection == nil)
        // The env list succeeded, so there's no error banner.
        #expect(harness.lastError == nil)
    }

    @Test
    func statusOnlyRowsCoverUngroupedGatewayPlatforms() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envJSON),
            .init(path: "/api/status", body: Self.statusWithStatusOnlyJSON),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.refresh()

        // Telegram has a messaging var → editable group, never a status-only row.
        #expect(harness.groups.contains { $0.id == "telegram" })
        // Signal has no messaging var but the gateway reports it → status-only.
        #expect(harness.statusOnlyRows.map(\.id) == ["signal"])
        let signal = try #require(harness.statusOnlyRows.first)
        #expect(signal.platform.state == "error")
        #expect(signal.platform.errorMessage == "not linked")
    }

    @Test
    func homeAssistantHasNoDuplicateStatusOnlyRow() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envHassJSON),
            .init(path: "/api/status", body: Self.statusHassJSON),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.refresh()

        // One editable Home Assistant card keyed to the gateway status key…
        let ha = try #require(harness.groups.first { $0.id == "homeassistant" })
        #expect(ha.displayName == "Home Assistant")
        #expect(ha.connection?.state == "connected")
        // …and no "Hass" auto-group nor a duplicate status-only row.
        #expect(harness.groups.contains { $0.id == "hass" } == false)
        #expect(harness.statusOnlyRows.contains { $0.id == "homeassistant" } == false)
    }

    @Test
    func listItemsPlaceEditablePlatformsBeforeStatusOnly() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envJSON),
            .init(path: "/api/status", body: Self.statusWithStatusOnlyJSON),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.refresh()

        // Editable groups come first, then status-only rows.
        let kinds = harness.listItems.map { item -> String in
            switch item {
            case .platform: return "platform:\(item.id)"
            case .statusOnly: return "statusOnly:\(item.id)"
            }
        }
        #expect(kinds == ["platform:telegram", "statusOnly:signal"])
    }

    @Test
    func selectedItemResolvesByID() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envJSON),
            .init(path: "/api/status", body: Self.statusWithStatusOnlyJSON),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.refresh()

        // Nothing selected → no detail pane.
        #expect(harness.selectedItem == nil)

        harness.selectionID = "telegram"
        if case let .platform(group)? = harness.selectedItem {
            #expect(group.id == "telegram")
        } else {
            Issue.record("Expected an editable platform for telegram")
        }

        harness.selectionID = "signal"
        if case let .statusOnly(row)? = harness.selectedItem {
            #expect(row.id == "signal")
        } else {
            Issue.record("Expected a status-only row for signal")
        }

        // A stale id matching nothing resolves to nil (panel hides).
        harness.selectionID = "does-not-exist"
        #expect(harness.selectedItem == nil)
    }

    @Test
    func saveIssuesPutWithExactKeyThenRefreshes() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.okJSON),       // PUT
            .init(path: "/api/env", body: Self.envJSON),      // refresh GET
            .init(path: "/api/status", body: Self.statusJSON), // refresh GET
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.save(key: "TELEGRAM_BOT_TOKEN", value: "new-token")

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/env"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["key"] as? String == "TELEGRAM_BOT_TOKEN")
        #expect(json["value"] as? String == "new-token")
        // Refresh ran after the write.
        #expect(harness.groups.contains { $0.id == "telegram" })
        #expect(harness.lastError == nil)
    }

    @Test
    func deleteIssuesDelete() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.okJSON),       // DELETE
            .init(path: "/api/env", body: Self.envJSON),      // refresh GET
            .init(path: "/api/status", body: Self.statusJSON), // refresh GET
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.delete(key: "TELEGRAM_BOT_TOKEN")

        let request = try #require(http.recordedRequests.first {
            $0.httpMethod == "DELETE" && $0.url?.path == "/api/env"
        })
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["key"] as? String == "TELEGRAM_BOT_TOKEN")
        #expect(harness.lastError == nil)
    }

    @Test
    func revealValueReturnsPlaintext() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env/reveal", body: Data(#"{"key":"TELEGRAM_BOT_TOKEN","value":"plain-secret"}"#.utf8)),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        let value = await harness.revealValue(key: "TELEGRAM_BOT_TOKEN")

        // The plaintext is returned to the caller (the field's view state), not
        // retained on the harness — so there's no cache to linger past a row.
        #expect(value == "plain-secret")
        #expect(harness.lastError == nil)
    }

    @Test
    func revealValueReturnsNilAndSetsErrorOnFailure() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(
                path: "/api/env/reveal",
                statusCode: 429,
                body: Data(#"{"detail":"Too many reveal requests."}"#.utf8)
            ),
        ])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        let value = await harness.revealValue(key: "TELEGRAM_BOT_TOKEN")

        #expect(value == nil)
        #expect(harness.lastError != nil)
    }

    @Test
    func restartGatewayNoOpsWithoutRunner() async throws {
        let http = MessagingStubHTTP(responses: [])
        let harness = GatewayHarness(client: makeClient(http), runner: nil)

        await harness.restartGateway()

        #expect(harness.hasRunner == false)
        #expect(harness.restartBusy == false)
        #expect(http.recordedRequests.isEmpty)
    }

    @Test
    func restartGatewayRunsCommandWithRunner() async throws {
        let http = MessagingStubHTTP(responses: [
            .init(path: "/api/env", body: Self.envJSON),       // refresh GET
            .init(path: "/api/status", body: Self.statusJSON), // refresh GET
        ])
        let runner = StubMessagingRunner(.success(HermesAdminResult(exitCode: 0, stdout: "", stderr: "")))
        let harness = GatewayHarness(client: makeClient(http), runner: runner)

        await harness.restartGateway()

        #expect(runner.received == [["gateway", "restart"]])
        #expect(harness.lastError == nil)
    }

    // MARK: - Helpers

    private func makeClient(_ http: MessagingStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Canned `HermesAdminRunning` recording the verb arguments it receives.
private final class StubMessagingRunner: HermesAdminRunning, @unchecked Sendable {
    let result: Result<HermesAdminResult, Error>
    private(set) var received: [[String]] = []

    init(_ result: Result<HermesAdminResult, Error>) { self.result = result }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        received.append(command.arguments)
        return try result.get()
    }
}

/// Path-matching HTTP stub (serves same-path responses in queue order) so the
/// concurrent env + status fetches and the post-write refresh resolve
/// deterministically regardless of which `async let` lands first.
private final class MessagingStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "MessagingStubHTTP")
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
