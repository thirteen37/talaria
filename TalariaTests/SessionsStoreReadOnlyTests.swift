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
