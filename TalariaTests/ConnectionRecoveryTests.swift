import Foundation
import HermesKit
import SwiftUI
import Testing
@testable import Talaria

/// Covers the iOS/iPad background→foreground connection recovery: the
/// scene-phase latch, the harness liveness probe + re-entrancy guard, and the
/// store's live-session re-resume. `TalariaTests` builds the macOS target, but
/// the recovery orchestration lives on the shared `ServerWindowHarness` class
/// and `SessionsStore`, so it exercises here.
@MainActor
@Suite
struct ConnectionRecoveryTests {
    // MARK: - BackgroundResumeLatch

    @Test
    func latchDoesNotFireOnInactiveBlip() {
        var latch = BackgroundResumeLatch()
        // active → inactive → active (control-center pull / app-switcher peek):
        // never reaches .background, so it must never fire.
        #expect(latch.note(.active) == false)
        #expect(latch.note(.inactive) == false)
        #expect(latch.note(.active) == false)
    }

    @Test
    func latchFiresOnceAfterRealBackgrounding() {
        var latch = BackgroundResumeLatch()
        #expect(latch.note(.active) == false)
        #expect(latch.note(.inactive) == false)
        #expect(latch.note(.background) == false)
        #expect(latch.note(.inactive) == false)
        // The .active completing the round-trip fires exactly once…
        #expect(latch.note(.active) == true)
        // …and doesn't re-fire without another backgrounding.
        #expect(latch.note(.inactive) == false)
        #expect(latch.note(.active) == false)
    }

    // MARK: - isDashboardAlive

    @Test
    func isDashboardAliveFalseWithoutClient() async {
        let harness = ServerWindowHarness.makeMock()
        #expect(await harness.isDashboardAlive() == false)
    }

    @Test
    func isDashboardAliveTrueWhenStatusResponds() async {
        let harness = ServerWindowHarness.makeMock()
        harness.dashboardClient = Self.client(RecoveryStubHTTP())
        #expect(await harness.isDashboardAlive() == true)
    }

    @Test
    func isDashboardAliveFalseWhenStatusHangs() async {
        let harness = ServerWindowHarness.makeMock()
        harness.dashboardClient = Self.client(RecoveryStubHTTP(statusHangs: true))
        // A half-open tunnel hangs; the short timeout must resolve it to false
        // rather than blocking on the 30s request timeout.
        #expect(await harness.isDashboardAlive(timeout: 0.3) == false)
    }

    // MARK: - Re-entrancy guards

    @Test
    func recoverConnectionIfNeededIsNoOpWhileRecovering() {
        let harness = ServerWindowHarness.makeMock()
        harness.dashboardStarted = true
        harness.isRecovering = true
        harness.recoverConnectionIfNeeded()
        // Guard short-circuits before spawning, so no recovery task is created
        // (no double-spawn).
        #expect(harness.recoveryTask == nil)
    }

    @Test
    func manualReconnectIsNoOpWhileRecovering() {
        let harness = ServerWindowHarness.makeMock()
        harness.isRecovering = true
        harness.reconnectDashboard()
        #expect(harness.recoveryTask == nil)
    }

    // MARK: - recoverLiveSessions

    @Test
    func recoverLiveSessionsReResumesLiveTabsAndPreservesOthers() async throws {
        let factory = CountingBackendFactory()
        let http = RecoveryStubHTTP(missingDetailIds: ["lost-1"])
        let store = SessionsStore(
            manager: SessionManager(backendFactory: { await factory.makeBackend() }),
            dashboardClient: Self.client(http),
            defaultCwd: "/tmp"
        )

        // Two editable live tabs, one read-only tab, one (soon-to-be) lost tab.
        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live 1", source: "acp"))
        await store.openExisting(HermesSessionSummary(id: "live-2", title: "Live 2", source: "acp"))
        await store.openExisting(HermesSessionSummary(id: "ext-1", title: "External", source: "telegram"))
        await store.openExisting(HermesSessionSummary(id: "lost-1", title: "Lost", source: "acp"))

        // Three acp opens booted three backends; the read-only tab booted none.
        let bootedAfterOpen = await factory.count
        #expect(bootedAfterOpen == 3)
        #expect(store.viewModel(for: "ext-1")?.isReadOnly == true)
        let readOnlyMessagesBefore = store.viewModel(for: "ext-1")?.messages.map(\.text)

        await store.recoverLiveSessions()

        // The two editable live tabs each re-resumed over the fresh tunnel (two
        // more backends); the lost + read-only tabs did not.
        #expect(await factory.count == 5)
        #expect(store.viewModel(for: "live-1")?.isReadOnly == false)
        #expect(store.viewModel(for: "live-1")?.hasError == false)
        #expect(store.viewModel(for: "live-2")?.hasError == false)

        // The non-persisted tab is marked lost (not re-resumed), transcript kept.
        let lost = try #require(store.viewModel(for: "lost-1"))
        #expect(lost.hasError == true)
        #expect(lost.statusText?.contains("Connection lost") == true)

        // The read-only tab is untouched.
        #expect(store.viewModel(for: "ext-1")?.isReadOnly == true)
        #expect(store.viewModel(for: "ext-1")?.messages.map(\.text) == readOnlyMessagesBefore)

        for id in ["live-1", "live-2", "ext-1", "lost-1"] {
            await store.closeTab(id)
        }
    }

    // MARK: - Helpers

    private static func client(_ http: RecoveryStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Counts backends vended so a test can assert how many live sessions were
/// (re-)resumed.
private actor CountingBackendFactory {
    private(set) var count = 0

    func makeBackend() -> any ChatBackend {
        count += 1
        return MockChatBackend()
    }
}

/// Path-keyed dashboard HTTP stub for the recovery tests. Answers `/api/status`
/// (optionally hanging to simulate a half-open tunnel), session-detail lookups
/// (404 for ids in `missingDetailIds`, so they read as non-resumable), and
/// message fetches (a one-message transcript so the re-seed has content).
private final class RecoveryStubHTTP: DashboardHTTP, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecoveryStubHTTP")
    private let missingDetailIds: Set<String>
    private let statusHangs: Bool

    init(missingDetailIds: Set<String> = [], statusHangs: Bool = false) {
        self.missingDetailIds = missingDetailIds
        self.statusHangs = statusHangs
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let path = url.path

        if path == "/api/status" {
            if statusHangs {
                // Long enough to outlast any test timeout; cancelled by
                // `withTimeout` when the probe deadline fires.
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return Self.ok(url, Data(#"{"version":"0.15.0"}"#.utf8))
        }
        if path.hasSuffix("/messages") {
            return Self.ok(url, Self.messagesBody)
        }
        if path.hasPrefix("/api/sessions/") {
            let id = String(path.dropFirst("/api/sessions/".count))
            if missingDetailIds.contains(id) {
                return Self.status(url, 404)
            }
            return Self.ok(url, Data(#"{"id":"\#(id)","source":"acp"}"#.utf8))
        }
        throw URLError(.unsupportedURL)
    }

    private static let messagesBody = Data(
        #"{"session_id":"x","messages":[{"role":"user","content":"history"}]}"#.utf8
    )

    private static func ok(_ url: URL, _ body: Data) -> (Data, URLResponse) {
        (body, response(url, 200))
    }

    private static func status(_ url: URL, _ code: Int) -> (Data, URLResponse) {
        (Data(), response(url, code))
    }

    private static func response(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
