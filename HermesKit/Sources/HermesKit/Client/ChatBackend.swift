import Foundation

/// The live-chat client surface `SessionManager` and the chat UI depend on.
/// Live chat runs over the Hermes dashboard `/api/ws` gateway
/// (``GatewayChatClient``); this protocol stays as the seam that keeps
/// `SessionManager` independent of the concrete client and lets tests inject a
/// scripted backend.
public protocol ChatBackend: Sendable {
    /// Stream of session updates / permission requests consumed by
    /// `SessionManager.pump`.
    nonisolated var notifications: AsyncThrowingStream<HermesNotification, Error> { get }

    /// Bring the backend up to the point where sessions can be created (the
    /// gateway client ensures its socket handshake landed).
    func start(clientInfo: Implementation) async throws

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse
    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse

    /// Run one turn. Resolves when the turn ends (the `message.complete` event),
    /// with streaming surfaced via ``notifications`` in the meantime.
    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse
    func cancel(sessionId: SessionId) async throws

    /// Reply to a server→client request the UI couldn't satisfy. The gateway
    /// never sends client-bound requests, so this is a no-op there — kept for the
    /// `.request` notification path the UI still handles defensively.
    func respond(id: JSONRPCID, error: JSONRPCError) async throws

    func close() async
}

public extension ChatBackend {
    /// Convenience text-prompt overload.
    func prompt(sessionId: SessionId, content: String) async throws -> PromptResponse {
        try await prompt(sessionId: sessionId, content: [.text(content)])
    }
}
