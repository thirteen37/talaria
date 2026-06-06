import Foundation
import HermesKit

/// In-process ``ChatBackend`` for UI previews and the mock window harness — no
/// SSH, no dashboard, no WebSocket. Replaces the old `MockACPTransport`. Emits
/// nothing by default; callers can push notifications via ``emit(_:)``.
final class MockChatBackend: ChatBackend, @unchecked Sendable {
    nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>
    private let continuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private let sessionId: SessionId

    init(sessionId: SessionId = "mock-session") {
        self.sessionId = sessionId
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { captured = $0 }
        self.continuation = captured!
    }

    func emit(_ notification: HermesNotification) {
        continuation.yield(notification)
    }

    func start(clientInfo: Implementation) async throws {}

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: sessionId)
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}
    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}
