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

public extension PromptResponse {
    /// The raw gateway completion status (`complete`, `end_turn`, `max_tokens`,
    /// `aborted`, a novel string, …) carried verbatim from `message.complete`,
    /// when present. Lets the UI show the *true* reason a turn ended instead of
    /// collapsing everything to "end_turn". Nil for non-gateway backends.
    var gatewayStatus: String? {
        if case let .string(value)? = meta?["gatewayStatus"] { return value }
        return nil
    }

    /// Whether this turn ended cleanly (the agent finished normally). Derived
    /// from the raw gateway status via ``GatewayChatClient/isCleanCompletion(_:)``
    /// — the SAME clean-set the `turnEnded` banner uses — so the queue-drain
    /// decision and the banner never disagree. Falls back to the typed
    /// `stopReason` when no raw status was carried (non-gateway backends).
    var isCleanTurnEnd: Bool {
        guard let gatewayStatus else { return stopReason == .endTurn }
        return GatewayChatClient.isCleanCompletion(gatewayStatus)
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
    /// The window's Hermes profile, sent as the `profile` param on `session.create`
    /// / `session.resume` so the gateway resolves the right `HERMES_HOME` (it reads
    /// `profile` from the JSON-RPC params, not the WS URL). `nil` for the default
    /// profile, which the gateway treats as the launch home (a harmless no-op).
    private let hermesProfileName: String?
    private let onClose: (@Sendable () async -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let notificationContinuation: AsyncThrowingStream<HermesNotification, Error>.Continuation

    private var nextId = 1
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var turnContinuation: CheckedContinuation<PromptResponse, Error>?
    /// Monotonic id for the current turn, bumped each time a turn is established.
    /// The prompt's unstructured attach/submit task captures the value at launch
    /// and re-checks it after every `await`, so a stale task (whose turn was
    /// cancelled and replaced by a newer turn) recognises it is no longer live —
    /// the bare `turnContinuation != nil` check can't tell *this* turn from a
    /// successor that happens to be running. See `prompt(sessionId:content:)`.
    private var turnToken = 0
    private var permissionCounter = 0
    /// Whether any `reasoning.delta` chunk streamed this turn — gates the
    /// redundant full-text `reasoning.available` emit. Reset on `message.start`.
    private var sawReasoningDelta = false
    /// Whether a message cycle is in flight: set on `message.start`, cleared on
    /// `message.complete`. Tracks *every* turn — including the autonomous
    /// continuations Hermes chains after the prompt resolves (`turnContinuation`
    /// is nil for those) — so a standalone `error` event can tell an aborted
    /// in-flight cycle (emit `.turnEnded(clean: false)` to consume the store's
    /// arm) from a passive error with no cycle (must not, or it would cancel a
    /// legitimately-scheduled fire from the preceding turn).
    private var messageCycleActive = false
    /// Per-turn `message.delta` tally — chunk count and total character length —
    /// reset on `message.start` and logged on `message.complete`. Counts/lengths
    /// only (never frame text), so the next truncation is attributable: "few
    /// deltas then complete" (Hermes/model early stop) vs "deltas flowing then a
    /// transport drop". See CLAUDE.md (log no frame contents).
    private var deltaCount = 0
    private var deltaChars = 0

    /// The id `SessionManager` registered this session under and the gateway's
    /// runtime id. Equal for new sessions; on resume `bound` is the stored id
    /// the UI uses while `runtime` is the gateway's per-process id.
    private var boundSessionId: SessionId?
    private var runtimeSessionId: String?
    private var closed = false

    /// - Parameter onClose: invoked once when the client closes, so callers can
    ///   release a shared resource (e.g. the dashboard supervisor refcount that
    ///   keeps `hermes dashboard` alive for this session).
    /// - Parameter hermesProfileName: the window's Hermes profile. Normalized to
    ///   `nil` when empty or the default profile name, so the `profile` param is
    ///   only emitted for a real non-default profile (mirrors `HermesProfiles.cliFlag`).
    public init(
        webSocket: any GatewayWebSocket,
        hermesProfileName: String? = nil,
        onClose: (@Sendable () async -> Void)? = nil
    ) {
        self.ws = webSocket
        if let name = hermesProfileName, !name.isEmpty, name != HermesProfiles.defaultProfileName {
            self.hermesProfileName = name
        } else {
            self.hermesProfileName = nil
        }
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
        let result = try await call("session.create", CreateParams(cols: 96, cwd: cwd.isEmpty ? nil : cwd, profile: hermesProfileName))
        guard let sid = Self.string(Self.object(result)["session_id"]) else {
            throw GatewayChatError.sessionNotReady
        }
        runtimeSessionId = sid
        boundSessionId = sid
        emitSessionInfo(fromInfo: Self.object(result)["info"])
        // Populate the slash-command menu (the gateway exposes it via the
        // `commands.catalog` RPC, not an event). Fire-and-forget so session
        // open isn't delayed by it; the UI fills in when the result arrives.
        Task { await self.loadAvailableCommands() }
        return NewSessionResponse(sessionId: sid)
    }

    public func loadSession(
        sessionId: SessionId,
        cwd: String,
        mcpServers: [McpServer] = []
    ) async throws -> LoadSessionResponse {
        let result = try await call("session.resume", ResumeParams(sessionId: sessionId, cols: 96, profile: hermesProfileName))
        // The gateway returns its own runtime id; keep emitting under the id the
        // UI already knows (the stored id passed in).
        runtimeSessionId = Self.string(Self.object(result)["session_id"]) ?? sessionId
        boundSessionId = sessionId
        emitSessionInfo(fromInfo: Self.object(result)["info"])
        Task { await self.loadAvailableCommands() }
        return LoadSessionResponse()
    }

    /// Fetch the slash-command catalog (`commands.catalog`) and publish it as an
    /// `availableCommandsUpdate` so the composer's slash menu populates — the
    /// gateway exposes commands via this RPC rather than a streamed event.
    /// The result shape is `{pairs: [["/name","description"], …], …}`; we strip
    /// the leading `/` so names match the composer's `AvailableCommand` model.
    private func loadAvailableCommands() async {
        guard let result = try? await call("commands.catalog", EmptyParams()) else { return }
        guard case let .array(pairs)? = Self.object(result)["pairs"] else { return }
        let commands: [AvailableCommand] = pairs.compactMap { pair in
            guard case let .array(items) = pair, items.count >= 2,
                  let rawName = Self.string(items[0]), !rawName.isEmpty else { return nil }
            let name = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
            return AvailableCommand(name: name, description: Self.string(items[1]) ?? "")
        }
        guard !commands.isEmpty else { return }
        emit(.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: commands)))
    }

    public func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        guard turnContinuation == nil else { throw GatewayChatError.turnInProgress }
        let text = content.compactMap { $0.plainText }.joined()
        // Image blocks ride a two-step flow: each is attached via
        // `image.attach_bytes` *before* the `prompt.submit`, which Hermes then
        // consumes from the session's queued-image state on the next turn.
        let images: [ImageContent] = content.compactMap {
            if case let .image(image) = $0 { return image }
            return nil
        }
        let runtime = runtimeSessionId ?? sessionId

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PromptResponse, Error>) in
                turnContinuation = cont
                turnToken += 1
                let token = turnToken
                Task {
                    do {
                        // Attach each image (in order) before submitting the text.
                        // `content_base64` is a self-describing data URL; the
                        // filename carries the mime-derived extension. Any throw
                        // here (e.g. an old Hermes without the RPC) routes to
                        // `failTurn` just like a submit failure — same single-
                        // resolve, cancellation-safe path.
                        //
                        // The attach loop awaits each ack, so a cancel can race in
                        // between frames: `onCancel` resolves the turn and sends
                        // `session.interrupt`. This unstructured Task isn't part of
                        // that cancellation, so after every await we re-check that
                        // *this* turn is still live — `turnContinuation != nil` (the
                        // turn wasn't cancelled with nothing replacing it) AND
                        // `turnToken == token` (a newer turn hasn't started in the
                        // meantime). Both are needed: a bare nil-check would let a
                        // stale task whose turn was cancelled-then-replaced submit
                        // the old text into the *new* turn. Once either fails we stop
                        // attaching and never submit, so a turn the gateway was told
                        // to interrupt can't start streaming into an idle-looking UI.
                        // (Safe to read here: this Task inherits the actor's isolation.)
                        for (index, image) in images.enumerated() {
                            guard self.isTurnLive(token) else { return }
                            let dataURL = "data:\(image.mimeType);base64,\(image.data)"
                            let filename = "talaria-\(index + 1).\(Self.ext(forMime: image.mimeType))"
                            _ = try await call("image.attach_bytes", ImageAttachParams(
                                sessionId: runtime,
                                contentBase64: dataURL,
                                filename: filename
                            ))
                        }
                        guard self.isTurnLive(token) else { return }
                        // The ack is `{status:"streaming"}`; the turn resolves on
                        // the later `message.complete` event. The ack still
                        // surfaces immediate failures (e.g. "session busy").
                        _ = try await call("prompt.submit", PromptParams(sessionId: runtime, text: text))
                    } catch {
                        // Only fail the turn if this is still that turn — a stale
                        // task's error must not resolve a successor turn's continuation.
                        if self.turnToken == token { self.failTurn(error: error) }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelTurn(runtime: runtime) }
        }
    }

    /// File extension for an image mime type, used to name attached images
    /// (`talaria-1.png`). Falls back to `png` for unrecognised types.
    private static func ext(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/tiff": return "tiff"
        default: return "png"
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

    /// Run a slash command through the harness. The typed path for pending-input
    /// commands (`/undo`, `/retry`, `/queue`, …) is `command.dispatch`, so those
    /// are routed there directly; everything else tries `slash.exec` (the harness
    /// slash worker — `/help`, `/status`, `/model …`, `/compress`, …) and falls
    /// back to `command.dispatch` on any error (aliases, skills). Uses the
    /// request/response ``call(_:_:)`` helper, so it's independent of the turn
    /// lifecycle and never touches `turnContinuation`.
    ///
    /// Pending-input commands are dispatched directly rather than relying on
    /// `slash.exec` to *reject* them: some Hermes versions don't reject them, they
    /// return a success with empty `output`, which would silently no-op the command
    /// (e.g. `/retry` rendering "(no output)" and never retrying) because the
    /// `command.dispatch` fallback never fires.
    public func slash(sessionId: SessionId, command: String) async throws -> SlashOutcome {
        let runtime = runtimeSessionId ?? sessionId
        let bare = Self.stripLeadingSlashes(command)
        let parsed = SlashCommand(parsing: bare)
        if parsed.isPendingInput {
            return try await dispatchCommand(name: parsed.name, arg: parsed.arg, runtime: runtime)
        }
        do {
            let result = try await call("slash.exec", SlashExecParams(sessionId: runtime, command: bare))
            let p = Self.object(result)
            let output = Self.string(p["output"]) ?? ""
            // `slash.exec` may also carry a non-fatal `warning`; append it.
            if let warning = Self.string(p["warning"]), !warning.isEmpty {
                return .output([output, warning].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            return .output(output)
        } catch {
            return try await dispatchCommand(name: parsed.name, arg: parsed.arg, runtime: runtime)
        }
    }

    /// Run a command through `command.dispatch` and map its typed payload.
    private func dispatchCommand(name: String, arg: String, runtime: String) async throws -> SlashOutcome {
        let result = try await call("command.dispatch", CommandDispatchParams(sessionId: runtime, name: name, arg: arg))
        return try await mapDispatch(result, runtime: runtime, arg: arg)
    }

    /// Map a `command.dispatch` payload onto a ``SlashOutcome``. `alias` recurses
    /// back into ``slash(sessionId:command:)`` so the aliased target runs through
    /// the same `slash.exec`-first path.
    private func mapDispatch(_ result: JSONValue, runtime: String, arg: String) async throws -> SlashOutcome {
        let p = Self.object(result)
        switch Self.string(p["type"]) ?? "" {
        case "alias":
            let target = Self.string(p["target"]) ?? ""
            let next = arg.isEmpty ? target : "\(target) \(arg)"
            return try await slash(sessionId: runtime, command: next)
        case "skill":
            let name = Self.string(p["name"]) ?? ""
            return .submit(message: Self.string(p["message"]) ?? "", notice: "⚡ loading skill: \(name)")
        case "send":
            return .submit(message: Self.string(p["message"]) ?? "", notice: Self.string(p["notice"]))
        case "prefill":
            return .prefill(message: Self.string(p["message"]) ?? "", notice: Self.string(p["notice"]) ?? "")
        default:
            // `exec` / `plugin` (and any unknown type carrying output).
            return .output(Self.string(p["output"]) ?? "")
        }
    }

    /// Run a prompt concurrently in a background session via `prompt.background`
    /// (`/bg`). The gateway starts a detached agent thread and returns a
    /// `{task_id}`; completion arrives later as the `background.complete` event
    /// (mapped to ``SessionUpdate/backgroundComplete(taskId:text:)``). Unlike
    /// `prompt`, this never touches `turnContinuation` — it is not the foreground
    /// turn, so the live turn (if any) is unaffected.
    public func promptBackground(sessionId: SessionId, text: String) async throws -> String {
        let runtime = runtimeSessionId ?? sessionId
        let result = try await call("prompt.background", PromptParams(sessionId: runtime, text: text))
        guard let taskId = Self.string(Self.object(result)["task_id"]) else {
            throw GatewayChatError.server("background task did not start")
        }
        return taskId
    }

    /// Fork the current session into a new live session via `session.branch`.
    /// The gateway creates a new DB row (marked `_branched_from`), inits an agent,
    /// and returns the new runtime id + title + parent stored key. The new session
    /// is already live under the returned runtime id.
    public func branchSession(sessionId: SessionId, name: String?) async throws -> BranchResult {
        let runtime = runtimeSessionId ?? sessionId
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await call(
            "session.branch",
            BranchParams(sessionId: runtime, name: (trimmed?.isEmpty == false) ? trimmed : nil)
        )
        let o = Self.object(result)
        guard let newId = Self.string(o["session_id"]) else {
            throw GatewayChatError.server("branch did not return a session id")
        }
        return BranchResult(
            sessionId: newId,
            title: Self.string(o["title"]) ?? "",
            parent: Self.string(o["parent"]) ?? ""
        )
    }

    /// Request a `/handoff` to a messaging platform via `handoff.request`. The
    /// failure codes (4023–4027, 4009) come back as JSON-RPC errors carrying the
    /// gateway's human-readable message, surfaced verbatim by the caller.
    public func requestHandoff(sessionId: SessionId, platform: String) async throws -> HandoffRequestResult {
        let runtime = runtimeSessionId ?? sessionId
        let result = try await call("handoff.request", HandoffRequestParams(sessionId: runtime, platform: platform))
        let o = Self.object(result)
        return HandoffRequestResult(
            queued: Self.bool(o["queued"]) ?? true,
            sessionKey: Self.string(o["session_key"]) ?? "",
            platform: Self.string(o["platform"]) ?? platform,
            homeName: Self.string(o["home_name"]) ?? ""
        )
    }

    /// Poll the handoff state via `handoff.state`.
    public func handoffState(sessionId: SessionId) async throws -> HandoffState {
        let runtime = runtimeSessionId ?? sessionId
        let result = try await call("handoff.state", SessionIdParams(sessionId: runtime))
        let o = Self.object(result)
        return HandoffState(
            state: Self.string(o["state"]) ?? "",
            platform: Self.string(o["platform"]) ?? "",
            error: Self.string(o["error"]) ?? ""
        )
    }

    /// Mark an in-flight handoff failed via `handoff.fail` (poll timed out).
    public func failHandoff(sessionId: SessionId, error: String) async throws {
        let runtime = runtimeSessionId ?? sessionId
        _ = try await call("handoff.fail", HandoffFailParams(sessionId: runtime, error: error))
    }

    /// Rename the live session via the gateway `session.title` RPC. Returns the
    /// resolved title (the gateway echoes it back, possibly `pending` until the
    /// DB row is persisted).
    public func setTitle(sessionId: SessionId, title: String) async throws -> String {
        let runtime = runtimeSessionId ?? sessionId
        let result = try await call("session.title", SessionTitleParams(sessionId: runtime, title: title))
        return Self.string(Self.object(result)["title"]) ?? title
    }

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
            // Defense-in-depth (see docs/gateway-chat.md): today one socket hosts
            // exactly one session, but the gateway tags every turn event with the
            // runtime `session_id` and the protocol reserves socket-multiplexing
            // as a later optimization. Drop any event whose non-empty `session_id`
            // isn't ours so a foreign session's `message.complete` can never end
            // *this* turn. An empty/absent `session_id` is a global broadcast
            // (`gateway.ready`, `skin.changed`, …) and is always allowed through;
            // so is anything arriving before our runtime id is known.
            if let eventSid = Self.string(fields["session_id"]), !eventSid.isEmpty,
               let runtime = runtimeSessionId, eventSid != runtime {
                return
            }
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
                deltaCount += 1
                deltaChars += text.count
                emit(.agentMessageChunk(Content(content: .text(text))))
            }
        case "reasoning.delta":
            if let text = Self.string(p["text"]) {
                sawReasoningDelta = true
                emit(.agentThoughtChunk(Content(content: .text(text))))
            }
        case "reasoning.available":
            // `reasoning.available` carries the *full* reasoning text and has
            // replace semantics on the desktop. Talaria's thought stream only
            // appends, so emitting the full text after the incremental
            // `reasoning.delta` chunks would duplicate the reasoning. Only emit
            // it when no deltas streamed this turn (some models emit just the
            // available block).
            if !sawReasoningDelta, let text = Self.string(p["text"]) {
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
            emitSessionInfo(fromInfo: payload)
            if let usage = usageUpdate(from: p["usage"]) {
                emit(.usageUpdate(usage))
            }
        case "message.complete":
            if let usage = usageUpdate(from: p["usage"]) {
                emit(.usageUpdate(usage))
            }
            let status = Self.string(p["status"]) ?? "complete"
            // Lightweight turn diagnostics: status + per-turn delta tally (counts
            // and lengths only — never frame text, per CLAUDE.md). Makes the next
            // truncation attributable.
            HermesLog.gateway.info("turn end status=\(status, privacy: .public) deltas=\(self.deltaCount, privacy: .public) chars=\(self.deltaChars, privacy: .public)")
            messageCycleActive = false
            resolveTurn(status: status, errorText: Self.string(p["text"]))
            // Turn boundary: surface the end so the store can coalesce the
            // "agent finished" notification across chained continuation turns.
            // `clean` distinguishes a normal end from a non-clean terminal status
            // (interrupted/error/max_tokens/aborted/… which must not notify).
            // Uses the SAME clean-set `resolveTurn` reads via `isCleanTurnEnd`, so
            // the banner and the queue-drain decision never disagree.
            if let sid = boundSessionId {
                notificationContinuation.yield(.turnEnded(sid, clean: Self.isCleanCompletion(status)))
            }
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
            // An error aborting an *in-flight* cycle must consume the store's
            // "agent finished" arm like a clean end does, or the arm lingers and a
            // later autonomous turn fires a spurious notification. "In flight"
            // means a pending prompt OR a started-but-not-completed cycle (the
            // autonomous-continuation case, where `turnContinuation` is nil). It is
            // NOT a passive error with no cycle — emitting there would cancel a
            // legitimately-scheduled fire from the preceding turn.
            if turnContinuation != nil || messageCycleActive {
                if let sid = boundSessionId {
                    notificationContinuation.yield(.turnEnded(sid, clean: false))
                }
            }
            messageCycleActive = false
            if turnContinuation != nil {
                failTurn(error: GatewayChatError.server(message))
            } else {
                notificationContinuation.yield(
                    .clientRequestError(id: .string("gateway-error"), method: "event", message: message)
                )
            }
        case "message.start":
            // Turn boundary: reset per-turn reasoning de-dup state. The UI's
            // busy/turn-started state is already driven by the in-flight prompt.
            sawReasoningDelta = false
            messageCycleActive = true
            deltaCount = 0
            deltaChars = 0
            // Surface the start so the store holds (cancels) any pending
            // "agent finished" notification while a chained continuation runs.
            if let sid = boundSessionId {
                notificationContinuation.yield(.turnStarted(sid))
            }
        case "background.complete":
            // A `/bg` task finished (server-process thread). Surface it as a
            // session update so the chat can render the result + clear its live
            // "running" indicator; it's not a foreground turn, so `turnContinuation`
            // is untouched.
            emit(.backgroundComplete(
                taskId: Self.string(p["task_id"]) ?? "",
                text: Self.string(p["text"]) ?? ""
            ))
        default:
            // gateway.ready, thinking.delta (kawaii spinner), tool.generating,
            // status.update, skin.changed, subagent.*, voice.* — not needed for
            // v1 parity. See docs.
            break
        }
    }

    private func emit(_ update: SessionUpdate) {
        guard let sid = boundSessionId else { return }
        notificationContinuation.yield(.sessionUpdate(SessionNotification(sessionId: sid, update: update)))
    }

    /// Hermes `usage` keys vary; accept the common `{used,size}` plus the
    /// `context_*` aliases the gateway actually emits (`_get_usage` →
    /// `context_used` / `context_max`) and skip when neither is present.
    private func usageUpdate(from value: JSONValue?) -> UsageUpdate? {
        guard case let .object(u) = value else { return nil }
        let used = Self.int(u["used"]) ?? Self.int(u["context_used"])
        let size = Self.int(u["size"]) ?? Self.int(u["context_size"])
            ?? Self.int(u["context_length"]) ?? Self.int(u["context_max"])
        guard let used, let size else { return nil }
        return UsageUpdate(size: size, used: used, cost: u["cost"])
    }

    /// Surface the gateway's session metadata (model/mode alias, cwd, git
    /// branch) as a `sessionInfoUpdate` so the chat status bar can show the
    /// model badge and the correct branch — the latter matters for remote
    /// sessions, whose cwd lives on the host so a local `git` probe is wrong.
    /// Carried both in the `session.create`/`session.resume` result `info` and
    /// in the `session.info` event payload. Title is left nil so this never
    /// clobbers the agent-authored session title.
    private func emitSessionInfo(fromInfo value: JSONValue?) {
        let i = Self.object(value)
        let model = Self.string(i["model"])
        let cwd = Self.string(i["cwd"])
        let branchRaw = Self.string(i["branch"])
        let branch = (branchRaw?.isEmpty == false) ? branchRaw : nil
        guard model != nil || cwd != nil || branch != nil else { return }
        emit(.sessionInfoUpdate(SessionInfoUpdate(model: model, cwd: cwd, branch: branch)))
    }

    /// The exact gateway completion statuses that count as a *clean* turn end —
    /// the agent finished normally. Any other status (`max_tokens`, `aborted`,
    /// `refusal`, a disconnect-driven terminal status, a novel string Hermes may
    /// add, …) is a non-clean end: surfaced verbatim, but it must NOT drain the
    /// prompt queue or fire the "agent finished" banner. Single source of truth
    /// shared by the `message.complete` turn-end signal and ChatView's
    /// queue-drain decision (`PromptResponse.isCleanTurnEnd`). We deliberately do
    /// not map Hermes' vocabulary onto guessed `StopReason` cases — see the plan.
    static func isCleanCompletion(_ status: String) -> Bool {
        status == "complete" || status == "end_turn"
    }

    /// Gateway statuses that mean the turn was cancelled/interrupted (mapped to
    /// `StopReason.cancelled`). Like ``isCleanCompletion(_:)``, an exact match —
    /// not a guess.
    static func isCancelledCompletion(_ status: String) -> Bool {
        status == "interrupted" || status == "cancelled"
    }

    private func resolveTurn(status: String, errorText: String?) {
        guard let cont = turnContinuation else { return }
        turnContinuation = nil
        // A turn that completes with `status:"error"` is a failure even if no
        // separate `error` event preceded it — fail the prompt rather than
        // resolving it as a clean end-of-turn (which would swallow the error).
        if status == "error" {
            cont.resume(throwing: GatewayChatError.server(errorText ?? "Hermes reported an error"))
            return
        }
        // Keep a typed `StopReason` for control flow, but carry the *raw* status
        // string so the UI can show the truth verbatim (`max_tokens`, `aborted`,
        // a novel string) instead of collapsing everything to "end_turn". Only
        // an exact cancelled-set status maps to `.cancelled`; everything else
        // (clean and non-clean alike) keeps the neutral `.endTurn` typed reason —
        // cleanliness is read from the raw status via `isCleanTurnEnd`, not the
        // typed reason.
        let stopReason: StopReason = Self.isCancelledCompletion(status) ? .cancelled : .endTurn
        cont.resume(returning: PromptResponse(
            meta: ["gatewayStatus": .string(status)],
            stopReason: stopReason
        ))
    }

    private func failTurn(error: Error) {
        guard let cont = turnContinuation else { return }
        turnContinuation = nil
        cont.resume(throwing: error)
    }

    /// Whether the turn identified by `token` is still the live one: it wasn't
    /// cancelled (a continuation is present) and no newer turn has superseded it
    /// (the token still matches). The prompt's attach/submit task checks this
    /// after every await to decide whether to keep going.
    private func isTurnLive(_ token: Int) -> Bool {
        turnContinuation != nil && turnToken == token
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
        let event = PermissionRequestEvent(id: .string("approval-\(permissionCounter)"), request: request, kind: .permission) { [weak self] outcome in
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
        let event = PermissionRequestEvent(id: .string("clarify-\(permissionCounter)"), request: request, kind: .question) { [weak self] outcome in
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
        // sudo.request carries the label in `text`; secret.request in `prompt`.
        let prompt = Self.string(p["prompt"]) ?? Self.string(p["text"]) ?? (method == "sudo.respond" ? "Password required" : "Secret required")
        let toolCall = ToolCallUpdate(toolCallId: "secret-\(permissionCounter)", title: prompt, status: .pending)
        let options = [PermissionOption(optionId: "", name: "Cancel", kind: .rejectOnce)]
        let request = RequestPermissionRequest(sessionId: sid, toolCall: toolCall, options: options)
        let event = PermissionRequestEvent(id: .string("secret-\(permissionCounter)"), request: request, kind: .secret) { [weak self] outcome in
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

    private static func bool(_ value: JSONValue?) -> Bool? {
        if case let .bool(b) = value { return b }
        return nil
    }

    private static func key(for id: JSONRPCID) -> String {
        switch id {
        case let .string(s): return s
        case let .number(n): return String(n)
        }
    }

    /// Drop any leading `/`(s) so a typed `/help` becomes the bare `help` the
    /// harness slash worker expects. (Name/arg splitting for the
    /// `command.dispatch` fallback uses the shared ``SlashCommand`` parser.)
    private static func stripLeadingSlashes(_ s: String) -> String {
        String(s.drop(while: { $0 == "/" }))
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

    /// Encodes to `{}` — for RPCs whose params the gateway ignores (e.g.
    /// `commands.catalog`).
    private struct EmptyParams: Codable, Sendable {}

    private struct CreateParams: Codable, Sendable {
        let cols: Int
        let cwd: String?
        /// Omitted (nil) for the default profile — the gateway then uses its launch
        /// home. `JSONEncoder` skips nil optionals, so no key is emitted.
        let profile: String?
    }

    private struct ResumeParams: Codable, Sendable {
        let sessionId: String
        let cols: Int
        let profile: String?
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cols
            case profile
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

    private struct ImageAttachParams: Codable, Sendable {
        let sessionId: String
        let contentBase64: String
        let filename: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case contentBase64 = "content_base64"
            case filename
        }
    }

    private struct SessionIdParams: Codable, Sendable {
        let sessionId: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
        }
    }

    private struct SlashExecParams: Codable, Sendable {
        let sessionId: String
        let command: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case command
        }
    }

    private struct CommandDispatchParams: Codable, Sendable {
        let sessionId: String
        let name: String
        let arg: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case name
            case arg
        }
    }

    private struct BranchParams: Codable, Sendable {
        let sessionId: String
        /// Omitted when nil — the gateway then derives a lineage title.
        let name: String?
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case name
        }
    }

    private struct HandoffRequestParams: Codable, Sendable {
        let sessionId: String
        let platform: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case platform
        }
    }

    private struct HandoffFailParams: Codable, Sendable {
        let sessionId: String
        let error: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case error
        }
    }

    private struct SessionTitleParams: Codable, Sendable {
        let sessionId: String
        let title: String
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case title
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
