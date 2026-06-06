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
}

/// A pending permission/approval prompt: the request to render plus a callback
/// the UI invokes with the user's outcome (which the backend routes back to the
/// agent).
public struct PermissionRequestEvent: Sendable {
    public var id: JSONRPCID
    public var request: RequestPermissionRequest
    public var respond: @Sendable (PermissionOutcome) async -> Void

    public init(
        id: JSONRPCID,
        request: RequestPermissionRequest,
        respond: @escaping @Sendable (PermissionOutcome) async -> Void
    ) {
        self.id = id
        self.request = request
        self.respond = respond
    }
}

extension PermissionRequestEvent: Equatable {
    public static func == (lhs: PermissionRequestEvent, rhs: PermissionRequestEvent) -> Bool {
        lhs.id == rhs.id && lhs.request == rhs.request
    }
}
