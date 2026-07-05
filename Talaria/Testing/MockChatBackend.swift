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
        if UITestFlags.mockCommands {
            emitAvailableCommands()
        }
        return NewSessionResponse(sessionId: sessionId)
    }

    /// Reproduces the real-remote condition: the gateway populates the
    /// composer's slash catalog via an `availableCommandsUpdate`. Uses a
    /// representative slice of the Hermes command set (names with hyphens,
    /// colons, and shared prefixes exercise the ranking/word-boundary paths).
    private func emitAvailableCommands() {
        let commands = [
            AvailableCommand(name: "help", description: "Show help"),
            AvailableCommand(name: "model", description: "Switch the active model"),
            AvailableCommand(name: "queue", description: "Queue a message"),
            AvailableCommand(name: "steer", description: "Steer the running turn"),
            AvailableCommand(name: "background", description: "Run in the background"),
            AvailableCommand(name: "compact", description: "Compact the context"),
            AvailableCommand(name: "handoff", description: "Hand off to a platform"),
            AvailableCommand(name: "session:rename", description: "Rename the session"),
        ]
        emit(.sessionUpdate(SessionNotification(
            sessionId: sessionId,
            update: .availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: commands))
        )))
    }

    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse {
        LoadSessionResponse()
    }

    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: SessionId) async throws {}

    func promptBackground(sessionId: SessionId, text: String) async throws -> String {
        "mock-bg-task"
    }

    func respond(id: JSONRPCID, error: JSONRPCError) async throws {}
    func close() async { continuation.finish() }
}
