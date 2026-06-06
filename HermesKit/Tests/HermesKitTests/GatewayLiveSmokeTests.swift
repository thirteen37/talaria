import Foundation
import Testing
@testable import HermesKit

/// Opt-in live smoke test against a running `hermes dashboard`. Set
/// `HERMES_WS_LIVE_BASE` (e.g. `http://127.0.0.1:9191`) and `HERMES_WS_LIVE_TOKEN`
/// to exercise the real `URLSessionGatewayWebSocket` + `GatewayChatClient` path
/// end-to-end (connect → session.create). Skipped otherwise.
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
        print("LIVE session_id = \(response.sessionId)")
        #expect(!response.sessionId.isEmpty)
        await client.close()
    }
}
