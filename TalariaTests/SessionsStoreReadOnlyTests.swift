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
            manager: SessionManager(transportFactory: { try await transportFactory.makeTransport() }),
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
            manager: SessionManager(transportFactory: { try await transportFactory.makeTransport() }),
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
            manager: SessionManager(transportFactory: { try await transportFactory.makeTransport() }),
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
            manager: SessionManager(transportFactory: {
                TitleEmittingTransport(sessionId: "acp-1", titles: ["Renamed by Hermes"])
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
            manager: SessionManager(transportFactory: {
                // Emit a real title first, then a whitespace-only one; the guard
                // must keep the first title rather than blanking it.
                TitleEmittingTransport(sessionId: "acp-1", titles: ["Renamed by Hermes", "   "])
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

    func makeTransport() async throws -> any Transport {
        count += 1
        return LoadSessionTransport()
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

private actor LoadSessionTransport: Transport {
    nonisolated let inbound: AsyncThrowingStream<Data, Error>
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var closed = false

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inbound = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw TransportError.stdinClosed }
        guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: data) else {
            return
        }
        switch message.method {
        case ACPMethod.initialize:
            respond(
                id: message.id,
                result: InitializeResponse(
                    protocolVersion: 1,
                    agentInfo: Implementation(name: "TestHermes", version: "0.0.0")
                )
            )
        case ACPMethod.sessionLoad:
            respond(id: message.id, result: LoadSessionResponse())
        default:
            if let id = message.id {
                respond(id: id, result: JSONValue.null)
            }
        }
    }

    func close() async {
        closed = true
        continuation.finish()
    }

    private func respond<R: Codable & Sendable>(id: JSONRPCID?, result: R) {
        guard let id, let data = try? JSONRPCFramer.encode(JSONRPCResponse(id: id, result: result)) else {
            return
        }
        continuation.yield(data)
    }

    private struct IncomingMessage: Decodable {
        let id: JSONRPCID?
        let method: String?
    }
}

/// Like `LoadSessionTransport`, but after answering `session/load` it emits one
/// `session/update` notification per configured title — mirroring how Hermes
/// pushes an auto-generated session title to the client mid-chat.
private actor TitleEmittingTransport: Transport {
    nonisolated let inbound: AsyncThrowingStream<Data, Error>
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let sessionId: SessionId
    private let titles: [String?]
    private var closed = false

    init(sessionId: SessionId, titles: [String?]) {
        self.sessionId = sessionId
        self.titles = titles
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inbound = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw TransportError.stdinClosed }
        guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: data) else {
            return
        }
        switch message.method {
        case ACPMethod.initialize:
            respond(
                id: message.id,
                result: InitializeResponse(
                    protocolVersion: 1,
                    agentInfo: Implementation(name: "TestHermes", version: "0.0.0")
                )
            )
        case ACPMethod.sessionLoad:
            respond(id: message.id, result: LoadSessionResponse())
            for title in titles {
                emitTitle(title)
            }
        default:
            if let id = message.id {
                respond(id: id, result: JSONValue.null)
            }
        }
    }

    func close() async {
        closed = true
        continuation.finish()
    }

    private func emitTitle(_ title: String?) {
        let notification = JSONRPCNotification(
            method: ACPMethod.sessionUpdate,
            params: SessionNotification(
                sessionId: sessionId,
                update: .sessionInfoUpdate(SessionInfoUpdate(title: title))
            )
        )
        guard let data = try? JSONRPCFramer.encode(notification) else {
            return
        }
        continuation.yield(data)
    }

    private func respond<R: Codable & Sendable>(id: JSONRPCID?, result: R) {
        guard let id, let data = try? JSONRPCFramer.encode(JSONRPCResponse(id: id, result: result)) else {
            return
        }
        continuation.yield(data)
    }

    private struct IncomingMessage: Decodable {
        let id: JSONRPCID?
        let method: String?
    }
}
