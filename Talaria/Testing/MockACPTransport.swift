import Foundation
import HermesKit

/// Launch-argument flags the UI test bundle passes to the app.
enum UITestFlags {
    /// Replaces the SSH transport with ``MockACPTransport`` so the chat
    /// surface can be driven without a real server.
    static var mockServer: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestMockServer")
    }
}

/// Minimal in-process ACP server used by UI tests. Activated by the
/// `-uiTestMockServer` launch argument so the chat surface can be exercised
/// on the simulator without a real SSH host.
///
/// Answers just enough of the protocol for the navigation + chat loop:
/// `initialize`, `session/new`, and `session/prompt` (which replies with a
/// streamed agent message and an `end_turn` stop reason).
actor MockACPTransport: Transport {
    nonisolated let inbound: AsyncThrowingStream<Data, Error>
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var closed = false
    private var sessionCounter = 0

    init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inbound = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw TransportError.stdinClosed }
        // Each send is one newline-terminated JSON-RPC frame.
        guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: data),
              let method = message.method else {
            return
        }
        switch method {
        case ACPMethod.initialize:
            respond(
                id: message.id,
                result: InitializeResponse(
                    protocolVersion: 1,
                    agentInfo: Implementation(name: "MockHermes", version: "0.0.0")
                )
            )
        case ACPMethod.sessionNew:
            sessionCounter += 1
            respond(id: message.id, result: NewSessionResponse(sessionId: "mock-session-\(sessionCounter)"))
        case ACPMethod.sessionPrompt:
            if let session = message.sessionId {
                streamAgentReply(sessionId: session, text: "Hello from the mock Hermes server.")
            }
            respond(id: message.id, result: PromptResponse(stopReason: .endTurn))
        default:
            // Notifications (no id) like session/cancel need no reply; any
            // other request gets a null result so the client doesn't hang.
            if let id = message.id {
                respondNull(id: id)
            }
        }
    }

    func close() async {
        closed = true
        continuation.finish()
    }

    private func respond<R: Codable & Sendable>(id: JSONRPCID?, result: R) {
        guard let id, let data = try? JSONRPCFramer.encode(JSONRPCResponse(id: id, result: result)) else { return }
        continuation.yield(data)
    }

    private func respondNull(id: JSONRPCID) {
        if let data = try? JSONRPCFramer.encode(JSONRPCResponse<JSONValue>(id: id, result: .null)) {
            continuation.yield(data)
        }
    }

    private func streamAgentReply(sessionId: SessionId, text: String) {
        let notification = SessionNotification(
            sessionId: sessionId,
            update: .agentMessageChunk(ContentChunk(content: .text(text)))
        )
        if let data = try? JSONRPCFramer.encode(
            JSONRPCNotification(method: ACPMethod.sessionUpdate, params: notification)
        ) {
            continuation.yield(data)
        }
    }

    private struct IncomingMessage: Decodable {
        let id: JSONRPCID?
        let method: String?
        let params: Params?

        var sessionId: SessionId? { params?.sessionId }

        struct Params: Decodable {
            let sessionId: SessionId?
        }
    }
}
