import Foundation

public enum GatewayChatError: Error, Equatable, Sendable, LocalizedError {
    case turnInProgress
    case sessionNotReady
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .turnInProgress: return "A turn is already running for this session."
        case .sessionNotReady: return "Gateway session is not ready."
        case let .server(message): return message
        }
    }
}

/// Live-chat backend over the Hermes dashboard `/api/ws` JSON-RPC gateway.
/// Conforms to ``ChatBackend`` by mapping gateway events
/// (`message.delta`, `tool.start`, `approval.request`, …) onto the same
/// ``HermesNotification`` values the ACP ``HermesClient`` emits, so the chat UI
/// is identical regardless of backend. See `docs/gateway-chat.md` for the
/// frozen protocol.
///
/// One client wraps one ``GatewayWebSocket`` hosting one chat session. The
/// gateway assigns a *runtime* session id (used on outbound calls); the client
/// emits notifications under the id `SessionManager` registered (`boundSessionId`),
/// so resume (where the two differ) routes correctly.
public actor GatewayChatClient: ChatBackend {
    public nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>

    private let ws: any GatewayWebSocket
    private let onClose: (@Sendable () async -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let notificationContinuation: AsyncThrowingStream<HermesNotification, Error>.Continuation

    private var nextId = 1
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var turnContinuation: CheckedContinuation<PromptResponse, Error>?
    private var permissionCounter = 0

    /// The id `SessionManager` registered this session under and the gateway's
    /// runtime id. Equal for new sessions; on resume `bound` is the stored id
    /// the UI uses while `runtime` is the gateway's per-process id.
    private var boundSessionId: SessionId?
    private var runtimeSessionId: String?
    private var closed = false

    /// - Parameter onClose: invoked once when the client closes, so callers can
    ///   release a shared resource (e.g. the dashboard supervisor refcount that
    ///   keeps `hermes dashboard` alive for this session).
    public init(
        webSocket: any GatewayWebSocket,
        onClose: (@Sendable () async -> Void)? = nil
    ) {
        self.ws = webSocket
        self.onClose = onClose
        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.notificationContinuation = captured!
        Task { await self.readLoop() }
    }

    // MARK: - ChatBackend

    /// No ACP-style handshake: the socket connects in `init` and the gateway
    /// needs no `initialize`. Errors surface on the first `session.*` call.
    public func start(clientInfo: Implementation) async throws {}

    public func newSession(cwd: String, mcpServers: [McpServer] = []) async throws -> NewSessionResponse {
        let result = try await call("session.create", CreateParams(cols: 96, cwd: cwd.isEmpty ? nil : cwd))
        guard let sid = Self.string(Self.object(result)["session_id"]) else {
            throw GatewayChatError.sessionNotReady
        }
        runtimeSessionId = sid
        boundSessionId = sid
        return NewSessionResponse(sessionId: sid)
    }

    public func loadSession(
        sessionId: SessionId,
        cwd: String,
        mcpServers: [McpServer] = []
    ) async throws -> LoadSessionResponse {
        let result = try await call("session.resume", ResumeParams(sessionId: sessionId, cols: 96))
        // The gateway returns its own runtime id; keep emitting under the id the
        // UI already knows (the stored id passed in).
        runtimeSessionId = Self.string(Self.object(result)["session_id"]) ?? sessionId
        boundSessionId = sessionId
        return LoadSessionResponse()
    }

    public func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        guard turnContinuation == nil else { throw GatewayChatError.turnInProgress }
        let text = content.compactMap { $0.plainText }.joined()
        let runtime = runtimeSessionId ?? sessionId

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PromptResponse, Error>) in
                turnContinuation = cont
                Task {
                    do {
                        // The ack is `{status:"streaming"}`; the turn resolves on
                        // the later `message.complete` event. The ack still
                        // surfaces immediate failures (e.g. "session busy").
                        _ = try await call("prompt.submit", PromptParams(sessionId: runtime, text: text))
                    } catch {
                        self.failTurn(error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelTurn(runtime: runtime) }
        }
    }

    public func cancel(sessionId: SessionId) async throws {
        let runtime = runtimeSessionId ?? sessionId
        // Fire-and-forget: the turn ends via the `message.complete` event, so we
        // don't block on the interrupt's JSON-RPC ack.
        try await sendFrame("session.interrupt", SessionIdParams(sessionId: runtime))
    }

    /// The gateway never issues client-bound JSON-RPC requests, so there is
    /// nothing to reply to. No-op.
    public func respond(id: JSONRPCID, error: JSONRPCError) async throws {}

    public func close() async {
        guard !closed else { return }
        closed = true
        await ws.close()
        finish(error: nil)
        await onClose?()
    }

    // MARK: - Read loop

    private func readLoop() async {
        do {
            for try await frame in ws.messages {
                handleFrame(frame)
            }
            finish(error: closed ? nil : GatewayWebSocketError.closed)
        } catch {
            finish(error: closed ? nil : error)
        }
    }

    private func handleFrame(_ data: Data) {
        guard let envelope = try? decoder.decode(InboundEnvelope.self, from: data) else {
            return
        }

        if envelope.method == "event", let params = envelope.params {
            let fields = Self.object(params)
            guard let type = Self.string(fields["type"]) else { return }
            dispatchEvent(type: type, payload: fields["payload"])
            return
        }

        guard let id = envelope.id else { return }
        let key = Self.key(for: id)
        if let error = envelope.error {
            pending.removeValue(forKey: key)?.resume(
                throwing: GatewayChatError.server(error.message ?? "Hermes RPC failed")
            )
        } else {
            pending.removeValue(forKey: key)?.resume(returning: envelope.result ?? .null)
        }
    }

    // MARK: - Event → HermesNotification mapping

    private func dispatchEvent(type: String, payload: JSONValue?) {
        let p = Self.object(payload)
        switch type {
        case "message.delta":
            if let text = Self.string(p["text"]) {
                emit(.agentMessageChunk(Content(content: .text(text))))
            }
        case "reasoning.delta", "reasoning.available":
            if let text = Self.string(p["text"]) {
                emit(.agentThoughtChunk(Content(content: .text(text))))
            }
        case "tool.start":
            let toolId = Self.string(p["tool_id"]) ?? ""
            let name = Self.string(p["name"]) ?? "Tool"
            emit(.toolCall(ToolCall(
                toolCallId: toolId,
                title: name,
                status: .inProgress,
                rawInput: payload
            )))
        case "tool.progress":
            if let toolId = Self.string(p["tool_id"]) {
                emit(.toolCallUpdate(ToolCallUpdate(toolCallId: toolId, status: .inProgress)))
            }
        case "tool.complete":
            let toolId = Self.string(p["tool_id"]) ?? ""
            let name = Self.string(p["name"])
            var content: [ToolCallContent]?
            if let diff = Self.string(p["inline_diff"]), !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                content = [.diff(Diff(path: name ?? "", newText: diff))]
            } else if let summary = Self.string(p["summary"]) ?? Self.string(p["result"]) {
                content = [.content(Content(content: .text(summary)))]
            }
            emit(.toolCallUpdate(ToolCallUpdate(
                toolCallId: toolId,
                status: .completed,
                content: content,
                rawOutput: p["result"]
            )))
        case "session.info":
            if let usage = usageUpdate(from: p["usage"]) {
                emit(.usageUpdate(usage))
            }
        case "message.complete":
            if let usage = usageUpdate(from: p["usage"]) {
                emit(.usageUpdate(usage))
            }
            resolveTurn(status: Self.string(p["status"]) ?? "complete")
        case "approval.request":
            emitApproval(p)
        case "clarify.request":
            emitClarify(p)
        case "sudo.request":
            emitTextSecret(p, method: "sudo.respond", field: "password")
        case "secret.request":
            emitTextSecret(p, method: "secret.respond", field: "value")
        case "error":
            let message = Self.string(p["message"]) ?? "Hermes reported an error"
            if turnContinuation != nil {
                failTurn(error: GatewayChatError.server(message))
            } else {
                notificationContinuation.yield(
                    .clientRequestError(id: .string("gateway-error"), method: "event", message: message)
                )
            }
        default:
            // gateway.ready, message.start, thinking.delta (kawaii spinner),
            // tool.generating, status.update, skin.changed, background.complete,
            // subagent.*, voice.* — not needed for v1 parity. See docs.
            break
        }
    }

    private func emit(_ update: SessionUpdate) {
        guard let sid = boundSessionId else { return }
        notificationContinuation.yield(.sessionUpdate(SessionNotification(sessionId: sid, update: update)))
    }

    /// Hermes `usage` keys vary; accept the common `{used,size}` (and the
    /// `context_*` aliases) and skip when neither is present.
    private func usageUpdate(from value: JSONValue?) -> UsageUpdate? {
        guard case let .object(u) = value else { return nil }
        let used = Self.int(u["used"]) ?? Self.int(u["context_used"])
        let size = Self.int(u["size"]) ?? Self.int(u["context_size"]) ?? Self.int(u["context_length"])
        guard let used, let size else { return nil }
        return UsageUpdate(size: size, used: used, cost: u["cost"])
    }

    private func resolveTurn(status: String) {
        guard let cont = turnContinuation else { return }
        turnContinuation = nil
        let stopReason: StopReason = status == "interrupted" ? .cancelled : .endTurn
        cont.resume(returning: PromptResponse(stopReason: stopReason))
    }

    private func failTurn(error: Error) {
        guard let cont = turnContinuation else { return }
        turnContinuation = nil
        cont.resume(throwing: error)
    }

    private func cancelTurn(runtime: String) async {
        failTurn(error: CancellationError())
        _ = try? await sendFrame("session.interrupt", SessionIdParams(sessionId: runtime))
    }

    // MARK: - Permission mapping

    /// `approval.request` → a permission with allow/always/deny options whose
    /// `optionId` is the gateway `choice` value sent back via `approval.respond`.
    /// This is the full-parity path (dangerous-command / execute_code approvals).
    private func emitApproval(_ p: [String: JSONValue]) {
        guard let sid = boundSessionId else { return }
        permissionCounter += 1
        let command = Self.string(p["command"]) ?? ""
        let description = Self.string(p["description"]) ?? ""
        let title = !description.isEmpty ? description : (command.isEmpty ? "Approval required" : command)
        let content: [ToolCallContent]? = command.isEmpty ? nil : [.content(Content(content: .text(command)))]
        let toolCall = ToolCallUpdate(
            toolCallId: "approval-\(permissionCounter)",
            title: title,
            status: .pending,
            content: content
        )
        let options = [
            PermissionOption(optionId: "once", name: "Run", kind: .allowOnce),
            PermissionOption(optionId: "always", name: "Always allow", kind: .allowAlways),
            PermissionOption(optionId: "deny", name: "Reject", kind: .rejectOnce)
        ]
        let request = RequestPermissionRequest(sessionId: sid, toolCall: toolCall, options: options)
        let event = PermissionRequestEvent(id: .string("approval-\(permissionCounter)"), request: request) { [weak self] outcome in
            await self?.respondApproval(outcome: outcome)
        }
        notificationContinuation.yield(.permissionRequest(event))
    }

    private func respondApproval(outcome: PermissionOutcome) async {
        let choice: String
        switch outcome {
        case let .selected(selected): choice = selected.optionId   // "once" / "always" / "deny"
        case .cancelled, .raw: choice = "deny"
        }
        _ = try? await sendFrame("approval.respond", ApprovalRespondParams(choice: choice, sessionId: runtimeSessionId))
    }

    /// `clarify.request` → a permission. Multiple-choice clarifies map cleanly
    /// to one option per choice (answer = the chosen text). Free-text clarifies
    /// can't be captured by the option-only permission UI yet, so a single
    /// "Continue" option unblocks the agent with an empty answer; a proper
    /// text-input affordance is a documented follow-up (see docs/gateway-chat.md).
    private func emitClarify(_ p: [String: JSONValue]) {
        guard let sid = boundSessionId else { return }
        permissionCounter += 1
        let requestId = Self.string(p["request_id"]) ?? ""
        let question = Self.string(p["question"]) ?? "Clarification needed"
        let choices: [String] = {
            if case let .array(items) = p["choices"] {
                return items.compactMap { Self.string($0) }
            }
            return []
        }()
        let options: [PermissionOption] = choices.isEmpty
            ? [PermissionOption(optionId: "", name: "Continue", kind: .allowOnce)]
            : choices.map { PermissionOption(optionId: $0, name: $0, kind: .allowOnce) }
        let toolCall = ToolCallUpdate(toolCallId: "clarify-\(permissionCounter)", title: question, status: .pending)
        let request = RequestPermissionRequest(sessionId: sid, toolCall: toolCall, options: options)
        let event = PermissionRequestEvent(id: .string("clarify-\(permissionCounter)"), request: request) { [weak self] outcome in
            await self?.respondText(requestId: requestId, method: "clarify.respond", field: "answer", outcome: outcome)
        }
        notificationContinuation.yield(.permissionRequest(event))
    }

    /// `sudo.request` / `secret.request` → a permission. These need a secure
    /// text field the option-only UI can't provide yet, so for v1 any response
    /// unblocks the agent with an empty value (treated as cancel). Full capture
    /// is a documented follow-up.
    private func emitTextSecret(_ p: [String: JSONValue], method: String, field: String) {
        guard let sid = boundSessionId else { return }
        permissionCounter += 1
        let requestId = Self.string(p["request_id"]) ?? ""
        let prompt = Self.string(p["prompt"]) ?? (method == "sudo.respond" ? "Password required" : "Secret required")
        let toolCall = ToolCallUpdate(toolCallId: "secret-\(permissionCounter)", title: prompt, status: .pending)
        let options = [PermissionOption(optionId: "", name: "Cancel", kind: .rejectOnce)]
        let request = RequestPermissionRequest(sessionId: sid, toolCall: toolCall, options: options)
        let event = PermissionRequestEvent(id: .string("secret-\(permissionCounter)"), request: request) { [weak self] outcome in
            await self?.respondText(requestId: requestId, method: method, field: field, outcome: outcome)
        }
        notificationContinuation.yield(.permissionRequest(event))
    }

    private func respondText(requestId: String, method: String, field: String, outcome: PermissionOutcome) async {
        let answer: String
        switch outcome {
        case let .selected(selected): answer = selected.optionId
        case .cancelled, .raw: answer = ""
        }
        _ = try? await sendFrame(method, TextRespondParams(requestId: requestId, field: field, value: answer))
    }

    // MARK: - JSON-RPC plumbing

    private func call<P: Codable & Sendable>(_ method: String, _ params: P) async throws -> JSONValue {
        let id = "r\(nextId)"
        nextId += 1
        let request = JSONRPCRequest(id: .string(id), method: method, params: params)
        let data = try encoder.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await ws.send(data)
                } catch {
                    self.failPending(id: id, error: error)
                }
            }
        }
    }

    /// Send a request frame and return once it's on the wire, *without* awaiting
    /// the JSON-RPC response. Used for cancel + the permission responders, where
    /// the turn's progress is observed via events, not the ack. The server's
    /// (uncorrelated) response is harmlessly dropped by `handleFrame`.
    private func sendFrame<P: Codable & Sendable>(_ method: String, _ params: P) async throws {
        let id = "r\(nextId)"
        nextId += 1
        let request = JSONRPCRequest(id: .string(id), method: method, params: params)
        try await ws.send(try encoder.encode(request))
    }

    private func failPending(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finish(error: Error?) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error ?? GatewayWebSocketError.closed)
        }
        if let cont = turnContinuation {
            turnContinuation = nil
            cont.resume(throwing: error ?? GatewayWebSocketError.closed)
        }
        if let error {
            notificationContinuation.finish(throwing: error)
        } else {
            notificationContinuation.finish()
        }
    }

    // MARK: - JSONValue helpers

    private static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case let .object(o) = value { return o }
        return [:]
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case let .string(s) = value { return s }
        return nil
    }

    private static func int(_ value: JSONValue?) -> Int? {
        if case let .number(n) = value { return Int(n) }
        return nil
    }

    private static func key(for id: JSONRPCID) -> String {
        switch id {
        case let .string(s): return s
        case let .number(n): return String(n)
        }
    }

    // MARK: - Wire structs

    private struct InboundEnvelope: Decodable {
        let id: JSONRPCID?
        let method: String?
        let result: JSONValue?
        let error: ErrorBody?
        let params: JSONValue?

        struct ErrorBody: Decodable {
            let message: String?
        }
    }

    private struct CreateParams: Codable, Sendable {
        let cols: Int
        let cwd: String?
    }

    private struct ResumeParams: Codable, Sendable {
        let sessionId: String
        let cols: Int
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cols
        }
    }

    private struct PromptParams: Codable, Sendable {
        let sessionId: String
        let text: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case text
        }
    }

    private struct SessionIdParams: Codable, Sendable {
        let sessionId: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
        }
    }

    private struct ApprovalRespondParams: Codable, Sendable {
        let choice: String
        let sessionId: String?
        enum CodingKeys: String, CodingKey {
            case choice
            case sessionId = "session_id"
        }
    }

    /// `clarify.respond {request_id, answer}` / `sudo.respond {request_id,
    /// password}` / `secret.respond {request_id, value}` — one struct, dynamic
    /// value key, since the three differ only in that field's name.
    private struct TextRespondParams: Codable, Sendable {
        let requestId: String
        let field: String
        let value: String

        init(requestId: String, field: String, value: String) {
            self.requestId = requestId
            self.field = field
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicKey.self)
            try container.encode(requestId, forKey: DynamicKey(stringValue: "request_id"))
            try container.encode(value, forKey: DynamicKey(stringValue: field))
        }

        init(from decoder: Decoder) throws {
            // Not used on the wire; present only to satisfy Codable.
            self.requestId = ""
            self.field = ""
            self.value = ""
        }

        private struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }
}
