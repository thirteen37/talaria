import Foundation
import Testing
@testable import HermesKit

/// Opt-in live smoke test against a running `hermes dashboard`. Set
/// `HERMES_WS_LIVE_BASE` (e.g. `http://127.0.0.1:9191`) and `HERMES_WS_LIVE_TOKEN`
/// to exercise the real `URLSessionGatewayWebSocket` + `GatewayChatClient` path
/// end-to-end (connect → session.create). Skipped otherwise.
/// Tiny actor so the notifications-reader Task can publish counts back to the
/// test body without data races.
private actor LiveCounter {
    private(set) var value = 0
    func set(_ v: Int) { value = v }
}

private func liveLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["HERMES_WS_LIVE_VERBOSE"] == "1" else { return }
    print(message())
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERMES_WS_LIVE_BASE"] != nil))
struct GatewayLiveSmokeTests {
    @Test
    func connectsAndCreatesSessionOverRealWebSocket() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(URL(string: env["HERMES_WS_LIVE_BASE"] ?? ""))
        let token = env["HERMES_WS_LIVE_TOKEN"] ?? ""

        let socket = try URLSessionGatewayWebSocket(dashboardBaseURL: base, credential: .token(token))
        let client = GatewayChatClient(webSocket: socket)
        try await client.start(clientInfo: Implementation(name: "smoke", version: "1.0"))
        let response = try await client.newSession(cwd: NSTemporaryDirectory())
        liveLog("LIVE session_id = \(response.sessionId)")
        #expect(!response.sessionId.isEmpty)
        await client.close()
    }

    /// Exercises the **exact** app path: scrape the token via `DashboardSession.refresh()`
    /// (the same call `resolveCredential` makes), then open the gateway socket with it.
    /// If the app gets 403 but a manually-scraped token gets 101, the divergence is here.
    @Test
    func scrapedTokenFromRefreshConnects() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(URL(string: env["HERMES_WS_LIVE_BASE"] ?? ""))

        let session = DashboardSession(baseURL: base)
        let token = try await session.refresh()
        liveLog("LIVE refresh() token len=\(token.count) head=\(token.prefix(6))")

        let socket = try URLSessionGatewayWebSocket(dashboardBaseURL: base, credential: .token(token))
        let client = GatewayChatClient(webSocket: socket)
        try await client.start(clientInfo: Implementation(name: "smoke-refresh", version: "1.0"))
        let response = try await client.newSession(cwd: NSTemporaryDirectory())
        liveLog("LIVE refresh-path session_id = \(response.sessionId)")
        #expect(!response.sessionId.isEmpty)
        await client.close()
    }

    /// Verifies the slash-command catalog and usage now reach the UI layer:
    /// after `newSession` the client should emit `availableCommandsUpdate`, and
    /// (with a prompt) `usageUpdate`. Set HERMES_WS_LIVE_PROMPT to exercise usage.
    @Test
    func surfacesCommandsAndUsage() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(URL(string: env["HERMES_WS_LIVE_BASE"] ?? ""))
        let token: String
        if let t = env["HERMES_WS_LIVE_TOKEN"], !t.isEmpty {
            token = t
        } else {
            token = try await DashboardSession(baseURL: base).refresh()
        }
        let socket = try URLSessionGatewayWebSocket(dashboardBaseURL: base, credential: .token(token))
        let client = GatewayChatClient(webSocket: socket)

        let commandCount = LiveCounter()
        let usageCount = LiveCounter()
        let reader = Task {
            for try await note in client.notifications {
                if case let .sessionUpdate(n) = note {
                    if case let .availableCommandsUpdate(u) = n.update {
                        await commandCount.set(u.availableCommands.count)
                        liveLog("COMMANDS: \(u.availableCommands.prefix(8).map(\.name))")
                    }
                    if case let .usageUpdate(u) = n.update {
                        await usageCount.set(1)
                        liveLog("USAGE: used=\(u.used) size=\(u.size)")
                    }
                    if case let .sessionInfoUpdate(u) = n.update {
                        liveLog("SESSION INFO: model=\(u.model ?? "nil") branch=\(u.branch ?? "nil")")
                    }
                }
            }
        }
        try await client.start(clientInfo: Implementation(name: "verify", version: "1.0"))
        _ = try await client.newSession(cwd: NSTemporaryDirectory())
        if let prompt = env["HERMES_WS_LIVE_PROMPT"], !prompt.isEmpty {
            _ = try? await client.prompt(sessionId: "ignored", content: [ContentBlock.text(prompt)])
        } else {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        reader.cancel()
        await client.close()
        let cmds = await commandCount.value
        let usageSeen = await usageCount.value
        liveLog("RESULT commands=\(cmds) usageSeen=\(usageSeen)")
        #expect(cmds > 0)
    }

    /// A rejected upgrade (wrong token → the dashboard closes with 403) must now
    /// surface the HTTP status via the delegate, not an opaque URLError.
    @Test
    func rejectedHandshakeSurfacesHTTPStatus() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(URL(string: env["HERMES_WS_LIVE_BASE"] ?? ""))

        let socket = try URLSessionGatewayWebSocket(dashboardBaseURL: base, credential: .token("definitely-wrong-token"))
        var thrown: Error?
        do {
            for try await _ in socket.messages { break }
        } catch {
            thrown = error
        }
        liveLog("LIVE rejection error = \(String(describing: thrown))")
        guard case let .closedWithCode(code)? = thrown as? GatewayWebSocketError else {
            Issue.record("expected GatewayWebSocketError.closedWithCode, got \(String(describing: thrown))")
            return
        }
        #expect(code == 403)
        await socket.close()
    }
}
