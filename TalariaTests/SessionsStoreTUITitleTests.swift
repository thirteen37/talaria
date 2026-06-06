import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Resumed Terminal (TUI) tabs bypass ACP, so they never get a live
/// `session_info_update`. `SessionsStore` instead polls the dashboard
/// (`GET /api/sessions`) and copies the persisted title into the sidebar row.
/// These cover that reconciler. The `TalariaTests` target is macOS-only, so the
/// TUI surface always compiles here.
@MainActor
@Suite
struct SessionsStoreTUITitleTests {
    @Test
    func resumedTUITabAdoptsDashboardTitle() async throws {
        let http = StubSessionsHTTP(sessions: [("sess-1", "Resumed Title")])
        let store = makeStore(http: http)

        // Seeded with an empty title (untitled at open time), as a freshly
        // resumed-from-browser row often is.
        await store.openTUI(resume: HermesSessionSummary(id: "sess-1", title: ""))

        try await waitUntil { store.openSessions.first?.title == "Resumed Title" }
        #expect(store.openSessions.first?.title == "Resumed Title")
        await store.closeTab(try #require(store.openSessions.first?.id))
    }

    @Test
    func whitespaceDashboardTitleNeverBlanksSeededTitle() async throws {
        let http = StubSessionsHTTP(sessions: [("sess-1", "   ")])
        let store = makeStore(http: http)

        await store.openTUI(resume: HermesSessionSummary(id: "sess-1", title: "Seeded"))

        // Let several polls run; the whitespace title must never overwrite the seed.
        try await sleep(.milliseconds(80))
        #expect(store.openSessions.first?.title == "Seeded")
        await store.closeTab(try #require(store.openSessions.first?.id))
    }

    @Test
    func closingLastResumedTUITabStopsPolling() async throws {
        let http = StubSessionsHTTP(sessions: [("sess-1", "Resumed Title")])
        let store = makeStore(http: http)

        await store.openTUI(resume: HermesSessionSummary(id: "sess-1", title: ""))
        try await waitUntil { store.openSessions.first?.title == "Resumed Title" }

        let tabId = try #require(store.openSessions.first?.id)
        await store.closeTab(tabId)

        // After the reconciler is torn down, the `/api/sessions` hit count must
        // stop growing across further poll intervals.
        try await sleep(.milliseconds(60))
        let settled = http.sessionsCallCount
        try await sleep(.milliseconds(60))
        #expect(http.sessionsCallCount == settled)
    }

    // MARK: - Helpers

    private func makeStore(http: StubSessionsHTTP) -> SessionsStore {
        SessionsStore(
            manager: SessionManager(backendFactory: { MockChatBackend() }),
            dashboardClient: DashboardClient(
                baseURL: URL(string: "http://127.0.0.1:9119")!,
                token: { "tok" },
                http: http
            ),
            defaultCwd: "/tmp",
            tuiSpecFactory: { _, cwd in
                TUILaunchSpec(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: ["hermes", "chat", "--tui"],
                    cwd: cwd
                )
            },
            tuiPollInterval: .milliseconds(10)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Always answers `GET /api/sessions` with the same configured session list, so
/// the title reconciler can poll it repeatedly, and counts how many times it was
/// hit (thread-safe) to prove polling starts and stops.
private final class StubSessionsHTTP: DashboardHTTP, @unchecked Sendable {
    private let queue = DispatchQueue(label: "StubSessionsHTTP")
    private let body: Data
    private var sessionsCalls = 0

    init(sessions: [(id: String, title: String)]) {
        let entries = sessions
            .map { #"{"id":"\#($0.id)","title":"\#($0.title)"}"# }
            .joined(separator: ",")
        self.body = Data(#"{"sessions":[\#(entries)]}"#.utf8)
    }

    var sessionsCallCount: Int {
        queue.sync { sessionsCalls }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.path == "/api/sessions" else {
            throw URLError(.unsupportedURL)
        }
        queue.sync { sessionsCalls += 1 }
        return (
            body,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

