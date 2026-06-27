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

    /// Run a prompt concurrently in a *background* session via the gateway
    /// `prompt.background` RPC (`/bg`). Returns the started task id immediately;
    /// the result arrives later as a ``SessionUpdate/backgroundComplete(taskId:text:)``
    /// session update (mapped from the `background.complete` event) — it is not an
    /// LLM turn and never resolves a `message.complete`.
    func promptBackground(sessionId: SessionId, text: String) async throws -> String

    /// Fork the current session's history into a new live session via the gateway
    /// `session.branch` RPC (`/branch` / `/fork`). Returns the new runtime session
    /// id, its title, and the parent's stored session key. Throws the harness error
    /// (4008) when there's nothing to branch (empty history).
    func branchSession(sessionId: SessionId, name: String?) async throws -> BranchResult

    /// Request a `/handoff` of this session to a messaging platform via
    /// `handoff.request`. Returns the queued state + resolved home channel name, or
    /// throws the harness error for the failure codes (4023 platform required, 4024
    /// unknown platform, 4025 not configured, 4026 no home channel, 4027 already in
    /// flight, 4009 busy). The transfer itself runs in a separate `hermes gateway`
    /// process; poll ``handoffState(sessionId:)`` for the terminal result.
    func requestHandoff(sessionId: SessionId, platform: String) async throws -> HandoffRequestResult

    /// Poll the in-flight `/handoff` state (`handoff.state`).
    func handoffState(sessionId: SessionId) async throws -> HandoffState

    /// Mark an in-flight `/handoff` failed (`handoff.fail`) so the user can retry —
    /// called when the bounded client-side poll times out.
    func failHandoff(sessionId: SessionId, error: String) async throws

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

/// The result of `session.branch`: a new live session forked from the caller's
/// history. ``sessionId`` is the new *runtime* id; ``parent`` is the parent's
/// *stored* session key (the `_branched_from` marker on the new DB row).
public struct BranchResult: Sendable, Equatable {
    public let sessionId: String
    public let title: String
    public let parent: String

    public init(sessionId: String, title: String, parent: String) {
        self.sessionId = sessionId
        self.title = title
        self.parent = parent
    }
}

/// Result of `handoff.request`: the handoff was queued onto the session row for
/// the separate `hermes gateway` process to pick up.
public struct HandoffRequestResult: Sendable, Equatable {
    public let queued: Bool
    public let sessionKey: String
    public let platform: String
    /// The destination home-channel name (for the "Handing off to …" line).
    public let homeName: String

    public init(queued: Bool, sessionKey: String, platform: String, homeName: String) {
        self.queued = queued
        self.sessionKey = sessionKey
        self.platform = platform
        self.homeName = homeName
    }
}

/// Result of `handoff.state`: the current transfer state plus any error text.
/// ``state`` is one of `pending` / `running` / `completed` / `failed`, or empty
/// when no handoff record exists.
public struct HandoffState: Sendable, Equatable {
    public let state: String
    public let platform: String
    public let error: String

    public init(state: String, platform: String, error: String) {
        self.state = state
        self.platform = platform
        self.error = error
    }
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

    /// Default: backends without a gateway can't run background prompts.
    /// ``GatewayChatClient`` overrides this.
    func promptBackground(sessionId: SessionId, text: String) async throws -> String {
        throw GatewayChatError.sessionNotReady
    }

    /// Default: backends without a gateway can't branch. ``GatewayChatClient``
    /// overrides this.
    func branchSession(sessionId: SessionId, name: String?) async throws -> BranchResult {
        throw GatewayChatError.sessionNotReady
    }

    /// Default: backends without a gateway can't hand off. ``GatewayChatClient``
    /// overrides these.
    func requestHandoff(sessionId: SessionId, platform: String) async throws -> HandoffRequestResult {
        throw GatewayChatError.sessionNotReady
    }

    func handoffState(sessionId: SessionId) async throws -> HandoffState {
        throw GatewayChatError.sessionNotReady
    }

    func failHandoff(sessionId: SessionId, error: String) async throws {
        throw GatewayChatError.sessionNotReady
    }
}
