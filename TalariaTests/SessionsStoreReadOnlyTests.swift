import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct SessionsStoreReadOnlyTests {
    @Test
    func nonACPSessionOpensReadOnlyWithoutStartingACP() async throws {
        let transportFactory = CountingTransportFactory()
        let http = StubDashboardHTTP(responses: [
            .init(
                path: "/api/sessions/external-1/messages",
                body: Self.messagesBody(sessionId: "external-1", text: "Hello from Telegram")
            )
        ])
        let store = SessionsStore(
            manager: SessionManager(backendFactory: { await transportFactory.makeBackend() }),
            dashboardClient: DashboardClient(
                baseURL: URL(string: "http://127.0.0.1:9119")!,
                token: { "tok" },
                http: http
            ),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "external-1", title: "External", source: "telegram"))

        #expect(await transportFactory.count == 0)
        #expect(store.selection == "external-1")
        let viewModel = try #require(store.viewModel(for: "external-1"))
        #expect(viewModel.isReadOnly == true)
        #expect(viewModel.messages.map(\.text) == ["Hello from Telegram"])
        #expect(http.recordedPaths == ["/api/sessions/external-1/messages"])
    }

    @Test
    func searchResultResolvesSourceBeforeOpeningReadOnly() async throws {
        let transportFactory = CountingTransportFactory()
        let http = StubDashboardHTTP(responses: [
            .init(path: "/api/sessions/search-hit", body: Data(#"{"id":"search-hit","source":"slack"}"#.utf8)),
            .init(
                path: "/api/sessions/search-hit/messages",
                body: Self.messagesBody(sessionId: "search-hit", text: "Hello from Slack")
            )
        ])
        let store = SessionsStore(
            manager: SessionManager(backendFactory: { await transportFactory.makeBackend() }),
            dashboardClient: DashboardClient(
                baseURL: URL(string: "http://127.0.0.1:9119")!,
                token: { "tok" },
                http: http
            ),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "search-hit", title: "Search hit"))

        #expect(await transportFactory.count == 0)
        let viewModel = try #require(store.viewModel(for: "search-hit"))
        #expect(viewModel.isReadOnly == true)
        #expect(viewModel.messages.map(\.text) == ["Hello from Slack"])
        #expect(http.recordedPaths == ["/api/sessions/search-hit", "/api/sessions/search-hit/messages"])
    }

    @Test
    func acpSessionUsesLiveACPPath() async throws {
        let transportFactory = CountingTransportFactory()
        let store = SessionsStore(
            manager: SessionManager(backendFactory: { await transportFactory.makeBackend() }),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "acp-1", title: "ACP", source: "acp"))

        #expect(await transportFactory.count == 1)
        let viewModel = try #require(store.viewModel(for: "acp-1"))
        #expect(viewModel.isReadOnly == false)
        await store.closeTab("acp-1")
    }

    @Test
    func acpSessionCapturesHermesEmittedTitle() async throws {
        let store = SessionsStore(
            manager: SessionManager(backendFactory: {
                TitleEmittingBackend(sessionId: "acp-1", titles: ["Renamed by Hermes"])
            }),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "acp-1", title: "ACP", source: "acp"))

        try await Self.waitUntil { store.openSessions.first?.title == "Renamed by Hermes" }
        #expect(store.openSessions.first?.title == "Renamed by Hermes")
        #expect(store.viewModel(for: "acp-1")?.title == "Renamed by Hermes")
        await store.closeTab("acp-1")
    }

    @Test
    func emptyTitleNotificationDoesNotBlankExistingTitle() async throws {
        let store = SessionsStore(
            manager: SessionManager(backendFactory: {
                // Emit a real title first, then a whitespace-only one; the guard
                // must keep the first title rather than blanking it.
                TitleEmittingBackend(sessionId: "acp-1", titles: ["Renamed by Hermes", "   "])
            }),
            defaultCwd: "/tmp"
        )

        await store.openExisting(HermesSessionSummary(id: "acp-1", title: "ACP", source: "acp"))

        try await Self.waitUntil { store.openSessions.first?.title == "Renamed by Hermes" }
        // Give the (in-order) empty-title notification a chance to be processed
        // too, so we'd catch a blanking regression.
        try await Self.waitUntil(timeout: .milliseconds(200)) { false }
        #expect(store.openSessions.first?.title == "Renamed by Hermes")
        #expect(store.viewModel(for: "acp-1")?.title == "Renamed by Hermes")
        await store.closeTab("acp-1")
    }

    /// Polls `condition` on the main actor until it holds or the timeout
    /// elapses, yielding between checks so the store's notification task can run.
    private static func waitUntil(
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

    private static func messagesBody(sessionId: String, text: String) -> Data {
        Data(
            """
            {
              "session_id": "\(sessionId)",
              "messages": [
                { "role": "user", "content": "\(text)" }
              ]
            }
            """.utf8
        )
    }
}

private actor CountingTransportFactory {
    private(set) var count = 0

    func makeBackend() -> any ChatBackend {
        count += 1
        return MockChatBackend()
    }
}

private final class StubDashboardHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        let body: Data
    }

    private let queue = DispatchQueue(label: "StubDashboardHTTP")
    private var responses: [Response]
    private var paths: [String] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var recordedPaths: [String] {
        queue.sync { paths }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response: Response? = queue.sync {
            paths.append(request.url?.path ?? "")
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let url = request.url, let response, url.path == response.path else {
            throw URLError(.unsupportedURL)
        }
        return (
            response.body,
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

/// A ``ChatBackend`` that, on `loadSession`, emits one session-info notification
/// per configured title — mirroring how Hermes pushes an auto-generated session
/// title to the client mid-chat. The updates are buffered until the manager's
/// pump subscribes (the replay path), so the store still sees them.
private final class TitleEmittingBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private let sessionId: SessionId
    private let titles: [String?]

    init(sessionId: SessionId, titles: [String?]) {
        self.sessionId = sessionId
        self.titles = titles
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: sessionId)
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        for title in titles {
            continuation.yield(.sessionUpdate(SessionNotification(
                sessionId: self.sessionId,
                update: .sessionInfoUpdate(SessionInfoUpdate(title: title))
            )))
        }
        return LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}
    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}
