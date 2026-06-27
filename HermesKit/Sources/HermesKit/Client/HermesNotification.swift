import Foundation

/// The chat event stream's element: session updates, permission requests, and a
/// few control cases. Emitted by ``GatewayChatClient`` (mapping dashboard
/// `/api/ws` gateway events) and consumed by `SessionManager` / the chat UI.
public enum HermesNotification: Equatable, Sendable {
    case sessionUpdate(SessionNotification)
    case permissionRequest(PermissionRequestEvent)
    case clientRequestError(id: JSONRPCID, method: String, message: String)
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case raw(method: String, params: JSONValue?)
    /// A turn (or chained continuation turn) began on this session. Transient
    /// control signal — used by the store to coalesce the "agent finished"
    /// notification across Hermes' chained `message.start … message.complete`
    /// cycles. Never buffered for replay (see `SessionManager.fanOut`).
    case turnStarted(SessionId)
    /// A turn ended. `clean == true` only for a normal end-of-turn
    /// (`status:"complete"`); `false` for `interrupted`/`error`. Transient
    /// control signal, never replayed.
    case turnEnded(SessionId, clean: Bool)
}

/// Distinguishes the three semantically different blocking prompts the gateway
/// emits, all of which ride the same ``PermissionRequestEvent``. Lets the UI
/// render an agent question or secure-value prompt differently from a real
/// allow/deny permission.
public enum UserPromptKind: Sendable, Equatable {
    case permission   // approval.request — allow/deny a tool action
    case question     // clarify.request — agent asking the user to choose/answer
    case secret       // sudo.request / secret.request — secure value entry
}

/// A pending permission/approval prompt: the request to render plus a callback
/// the UI invokes with the user's outcome (which the backend routes back to the
/// agent).
public struct PermissionRequestEvent: Sendable {
    public var id: JSONRPCID
    public var request: RequestPermissionRequest
    public var kind: UserPromptKind
    public var respond: @Sendable (PermissionOutcome) async -> Void

    public init(
        id: JSONRPCID,
        request: RequestPermissionRequest,
        kind: UserPromptKind = .permission,
        respond: @escaping @Sendable (PermissionOutcome) async -> Void
    ) {
        self.id = id
        self.request = request
        self.kind = kind
        self.respond = respond
    }
}

extension PermissionRequestEvent: Equatable {
    public static func == (lhs: PermissionRequestEvent, rhs: PermissionRequestEvent) -> Bool {
        lhs.id == rhs.id && lhs.request == rhs.request && lhs.kind == rhs.kind
    }
}
