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

    @Test
    func recoverLiveSessionsDoesNotSpuriouslyTriggerRecovery() async throws {
        // A full recovery closes each still-live manager session in step 1 before
        // re-resuming it. That deliberate close must not be mistaken for a silent
        // socket death: the VM's notification loop is cancelled first, so its
        // stream-end reads as intentional and never fires `handleLiveSessionDied`.
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        var recoveryTriggers = 0
        store.requestRecovery = { recoveryTriggers += 1 }
        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live", source: "acp"))

        await store.recoverLiveSessions()
        // Give any racing old-notification-task unwind a chance to (wrongly) fire.
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(recoveryTriggers == 0)

        await store.closeTab("live-1")
    }

    // MARK: - deadLiveSessionIds

    @Test
    func deadLiveSessionIdsEmptyForHealthyTab() async throws {
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live", source: "acp"))
        // A freshly-resumed live tab has an open stream — nothing dead.
        #expect(await store.deadLiveSessionIds().isEmpty)
        await store.closeTab("live-1")
    }

    @Test
    func deadLiveSessionIdsReportsTabAfterStreamEnds() async throws {
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live", source: "acp"))
        // Simulate the `/api/ws` socket dying: finish the backend's stream without
        // tearing the session down, exactly the WS-death-after-passing-probe case.
        await store.manager.client(for: "live-1")?.close()
        try await pollUntil { !(await store.deadLiveSessionIds()).isEmpty }
        #expect(await store.deadLiveSessionIds() == ["live-1"])
        await store.closeTab("live-1")
    }

    @Test
    func deadLiveSessionIdsEmptyForReadOnlyTab() async throws {
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        await store.openExisting(HermesSessionSummary(id: "ext-1", title: "External", source: "telegram"))
        #expect(store.viewModel(for: "ext-1")?.isReadOnly == true)
        // Read-only tabs have no manager session, so nothing can be dead.
        #expect(await store.deadLiveSessionIds().isEmpty)
        await store.closeTab("ext-1")
    }

    // MARK: - handleLiveSessionDied (macOS silent-WS-death trigger)

    @Test
    func handleLiveSessionDiedFiresRecoveryClosure() async {
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        var calls = 0
        store.requestRecovery = { calls += 1 }
        store.handleLiveSessionDied(id: "live-1")
        #expect(calls == 1)
    }

    @Test
    func handleLiveSessionDiedDebouncesRapidTriggers() async {
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        var calls = 0
        store.requestRecovery = { calls += 1 }
        // Two stream deaths in quick succession (a flapping socket, or several
        // chats' sockets dying together) collapse to a single recovery trigger —
        // the debounce window hasn't elapsed between the synchronous calls.
        store.handleLiveSessionDied(id: "live-1")
        store.handleLiveSessionDied(id: "live-2")
        #expect(calls == 1)
    }

    @Test
    func handleLiveSessionDiedNoOpWithoutRecoveryClosure() async {
        // No wired harness (mock/test) must not crash — the closure is optional.
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        store.handleLiveSessionDied(id: "live-1")
    }

    @Test
    func handleLiveSessionDiedRetriesThenGivesUpWhenRecoveryNeverSucceeds() async throws {
        // A fully-unreachable dashboard: the stub "recovery" only counts (never
        // re-resumes and never marks lost), so the session stays dead. The driver
        // must (a) retry more than once — not strand after a single shot — and then
        // (b) give up after a bounded number of stalled attempts, degrading to the
        // manual-Reconnect banner instead of looping forever. Inject a tiny cadence.
        let store = SessionsStore(
            manager: SessionManager(backendFactory: { MockChatBackend() }),
            dashboardClient: Self.client(RecoveryStubHTTP()),
            defaultCwd: "/tmp",
            recoveryDebounce: 0.02
        )
        var calls = 0
        store.requestRecovery = { calls += 1 }
        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live", source: "acp"))

        // Kill the socket; the VM observes the dead stream and starts the driver.
        await store.manager.client(for: "live-1")?.close()
        try await Task.sleep(nanoseconds: 300_000_000)   // many cadence windows
        let afterRetries = calls
        #expect(afterRetries >= 2)   // retried, not a one-shot

        // Bounded: the driver gave up rather than re-firing forever.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(calls == afterRetries)   // no further attempts — loop terminated
        #expect(calls <= 8)              // within the stall cap

        await store.closeTab("live-1")
    }

    // MARK: - openExisting(select:)

    @Test
    func openExistingWithSelectFalseOpensWithoutChangingSelection() async throws {
        // Cold-relaunch restore re-opens tabs without churning the visible selection
        // so it can set the recorded selection once at the end (and so a user tap is
        // an unambiguous signal). Verify the opt-out leaves `selection` untouched.
        let store = Self.makeStore(CountingBackendFactory(), Self.client(RecoveryStubHTTP()))
        #expect(store.selection == nil)

        await store.openExisting(HermesSessionSummary(id: "s1", title: "S1", source: "acp"), select: false)
        #expect(store.openSessions.contains { $0.id == "s1" })
        #expect(store.selection == nil)

        // The default still selects.
        await store.openExisting(HermesSessionSummary(id: "s2", title: "S2", source: "acp"))
        #expect(store.selection == "s2")

        await store.closeTab("s1")
        await store.closeTab("s2")
    }

    // MARK: - reopenForRestore

    @Test
    func reopenForRestoreSkipsDeletedSessionWithoutError() async throws {
        // A saved session that the server no longer has (404) must degrade silently
        // on cold relaunch — no tab, and crucially no `lastError` (which would pop a
        // red banner). An existing session opens (without selecting).
        let store = Self.makeStore(
            CountingBackendFactory(),
            Self.client(RecoveryStubHTTP(missingDetailIds: ["gone"]))
        )

        let deletedOpened = await store.reopenForRestore(id: "gone")
        #expect(deletedOpened == false)
        #expect(store.openSessions.contains { $0.id == "gone" } == false)
        #expect(store.lastError == nil)

        let liveOpened = await store.reopenForRestore(id: "live-1")
        #expect(liveOpened == true)
        #expect(store.openSessions.contains { $0.id == "live-1" })
        #expect(store.selection == nil)   // opened without selecting
        #expect(store.lastError == nil)

        await store.closeTab("live-1")
    }

    // MARK: - recoverConnectionIfNeeded: WS-death after a passing probe

    @Test
    func recoverConnectionReResumesDeadLiveSessionWithoutTeardown() async throws {
        let factory = CountingBackendFactory()
        let dashboard = Self.client(RecoveryStubHTTP())
        let store = Self.makeStore(factory, dashboard)
        let harness = ServerWindowHarness(
            store: store,
            profile: ServerProfile(name: "Server", kind: .ssh, host: "host")
        )
        harness.dashboardClient = dashboard
        store.dashboardClient = dashboard
        harness.dashboardStarted = true

        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live", source: "acp"))
        let bootedAfterOpen = await factory.count
        #expect(bootedAfterOpen == 1)

        // WS death while HTTP stays healthy.
        await store.manager.client(for: "live-1")?.close()
        try await pollUntil { !(await store.deadLiveSessionIds()).isEmpty }

        harness.recoverConnectionIfNeeded()
        await harness.recoveryTask?.value

        // The probe passed (HTTP alive), so the dead chat re-resumed over the same
        // tunnel — one more backend booted — and no full recovery ran: the dashboard
        // client is still present and unchanged, with no acquisition error.
        #expect(await factory.count == bootedAfterOpen + 1)
        #expect(harness.dashboardClient != nil)
        #expect(harness.dashboardError == nil)
        #expect(harness.isRecovering == false)

        await store.closeTab("live-1")
    }

    @Test
    func recoverConnectionReResumesOnlyTheDeadSessionNotHealthyOnes() async throws {
        // Each live chat owns its own socket, so a single channel reset can kill one
        // while the others stay healthy and mid-stream. Recovery must re-resume only
        // the dead one — tearing down a healthy chat would drop its in-flight turn.
        let factory = CountingBackendFactory()
        let dashboard = Self.client(RecoveryStubHTTP())
        let store = Self.makeStore(factory, dashboard)
        let harness = ServerWindowHarness(
            store: store,
            profile: ServerProfile(name: "Server", kind: .ssh, host: "host")
        )
        harness.dashboardClient = dashboard
        store.dashboardClient = dashboard
        harness.dashboardStarted = true

        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live 1", source: "acp"))
        await store.openExisting(HermesSessionSummary(id: "live-2", title: "Live 2", source: "acp"))
        #expect(await factory.count == 2)

        // Kill only live-1's socket.
        await store.manager.client(for: "live-1")?.close()
        try await pollUntil { !(await store.deadLiveSessionIds()).isEmpty }
        #expect(await store.deadLiveSessionIds() == ["live-1"])

        harness.recoverConnectionIfNeeded()
        await harness.recoveryTask?.value

        // Exactly one re-resume (live-1), not two — the healthy live-2 is untouched.
        #expect(await factory.count == 3)
        #expect(await store.deadLiveSessionIds().isEmpty)

        await store.closeTab("live-1")
        await store.closeTab("live-2")
    }

    @Test
    func recoverConnectionSkipsReResumeWhenNoDeadSession() async throws {
        let factory = CountingBackendFactory()
        let dashboard = Self.client(RecoveryStubHTTP())
        let store = Self.makeStore(factory, dashboard)
        let harness = ServerWindowHarness(
            store: store,
            profile: ServerProfile(name: "Server", kind: .ssh, host: "host")
        )
        harness.dashboardClient = dashboard
        store.dashboardClient = dashboard
        harness.dashboardStarted = true

        await store.openExisting(HermesSessionSummary(id: "live-1", title: "Live", source: "acp"))
        let bootedAfterOpen = await factory.count

        harness.recoverConnectionIfNeeded()
        await harness.recoveryTask?.value

        // Probe alive + nothing dead → no re-resume, no extra backend.
        #expect(await factory.count == bootedAfterOpen)
        #expect(harness.dashboardError == nil)

        await store.closeTab("live-1")
    }

    // MARK: - Helpers

    private static func makeStore(_ factory: CountingBackendFactory, _ dashboard: DashboardClient) -> SessionsStore {
        SessionsStore(
            manager: SessionManager(backendFactory: { await factory.makeBackend() }),
            dashboardClient: dashboard,
            defaultCwd: "/tmp"
        )
    }

    private static func client(_ http: RecoveryStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Polls `condition` until it holds (or a bounded number of attempts elapse), so
/// a test can wait on the session manager's pump observing an out-of-band stream
/// end without reaching into its private pump task.
private func pollUntil(
    attempts: Int = 200,
    _ condition: @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
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
