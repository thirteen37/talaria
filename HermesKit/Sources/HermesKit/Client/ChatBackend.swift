import Foundation

/// The subset of a live-chat client that `SessionManager` and the chat UI
/// actually use. It exists so the same `SessionManager` / `LocalChatViewModel`
/// pipeline can be driven by either backend during the migration off ACP:
///
/// - ``HermesClient`` (ACP over a byte ``Transport``) conforms as-is.
/// - ``GatewayChatClient`` (JSON-RPC over a ``GatewayWebSocket``) conforms by
///   mapping Hermes dashboard gateway events to the same ``HermesNotification``
///   values, so `ChatView` / `ChatModels` stay unchanged.
///
/// Once the WebSocket path reaches parity and ACP is removed (Phase 4), this
/// seam collapses back into a single concrete client.
public protocol ChatBackend: Sendable {
    /// Stream of session updates / permission requests, identical in shape to
    /// what the ACP client emits. Consumed by `SessionManager.pump`.
    nonisolated var notifications: AsyncThrowingStream<HermesNotification, Error> { get }

    /// Bring the backend up to the point where sessions can be created
    /// (ACP: send `initialize`; gateway: ensure the socket handshake landed).
    func start(clientInfo: Implementation) async throws

    func newSession(cwd: String, mcpServers: [McpServer]) async throws -> NewSessionResponse
    func loadSession(sessionId: SessionId, cwd: String, mcpServers: [McpServer]) async throws -> LoadSessionResponse

    /// Run one turn. Resolves when the turn ends (ACP: the prompt response;
    /// gateway: the `message.complete` event), with streaming surfaced via
    /// ``notifications`` in the meantime.
    func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse
    func cancel(sessionId: SessionId) async throws

    /// Reply to a server→client request the UI couldn't satisfy. ACP-only; the
    /// gateway never sends client-bound requests (no-op there).
    func respond(id: JSONRPCID, error: JSONRPCError) async throws

    func close() async
}

public extension ChatBackend {
    /// Convenience text-prompt overload shared by both backends.
    func prompt(sessionId: SessionId, content: String) async throws -> PromptResponse {
        try await prompt(sessionId: sessionId, content: [.text(content)])
    }
}

extension HermesClient: ChatBackend {
    /// ACP handshake. The `InitializeResponse` is unused by `SessionManager`.
    public func start(clientInfo: Implementation) async throws {
        _ = try await initialize(clientInfo: clientInfo)
    }
}
