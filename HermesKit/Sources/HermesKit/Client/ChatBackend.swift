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

    /// Run a slash command through the harness (NOT an LLM turn). Tries
    /// `slash.exec`, falls back to `command.dispatch`. No streaming / no
    /// `message.complete`; resolves on the single RPC response.
    func slash(sessionId: SessionId, command: String) async throws -> SlashOutcome

    /// Rename the live session via the gateway `session.title` RPC (maps the
    /// runtime id → session and queues when the DB row isn't persisted yet).
    /// Returns the resolved title.
    func setTitle(sessionId: SessionId, title: String) async throws -> String

    /// Reply to a server→client request the UI couldn't satisfy. The gateway
    /// never sends client-bound requests, so this is a no-op there — kept for the
    /// `.request` notification path the UI still handles defensively.
    func respond(id: JSONRPCID, error: JSONRPCError) async throws

    func close() async
}

/// The result of running a slash command through the harness. Distinguishes the
/// three ways Hermes resolves a command: render output as a system line, refill
/// the composer (`/undo`), or submit a message as a real LLM turn.
public enum SlashOutcome: Sendable, Equatable {
    /// Render as a system line (`slash.exec` output, or a `command.dispatch`
    /// `exec`/`plugin` payload).
    case output(String)
    /// Refill the composer with `message` after a system line `notice`. This is
    /// the `/undo` shape (`command.dispatch` `prefill`).
    case prefill(message: String, notice: String)
    /// Submit `message` as a real LLM prompt, optionally preceded by a system
    /// line `notice` (`command.dispatch` `send` / `skill`).
    case submit(message: String, notice: String?)
}

public extension ChatBackend {
    /// Convenience text-prompt overload.
    func prompt(sessionId: SessionId, content: String) async throws -> PromptResponse {
        try await prompt(sessionId: sessionId, content: [.text(content)])
    }

    /// Default: backends that don't drive the harness slash surface (mocks,
    /// read-only/scripted test doubles) reject slash commands. ``GatewayChatClient``
    /// overrides this.
    func slash(sessionId: SessionId, command: String) async throws -> SlashOutcome {
        throw GatewayChatError.sessionNotReady
    }

    /// Default: backends without a gateway can't rename. ``GatewayChatClient``
    /// overrides this.
    func setTitle(sessionId: SessionId, title: String) async throws -> String {
        throw GatewayChatError.sessionNotReady
    }
}
