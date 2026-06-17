import Foundation

public enum SessionManagerError: Error, Equatable, Sendable {
    case sessionNotFound(SessionId)
    case duplicateSession(SessionId)
}

public actor SessionManager {
    /// Produces a fresh, un-started ``ChatBackend`` per session (a
    /// ``GatewayChatClient`` over the dashboard `/api/ws` gateway).
    /// `SessionManager` calls ``ChatBackend/start(clientInfo:)`` on it before
    /// creating/loading a session.
    public typealias ChatBackendFactory = @Sendable () async throws -> any ChatBackend

    public struct ClientInfo: Sendable {
        public var name: String
        public var version: String
        public init(name: String = "Talaria", version: String = "1.0") {
            self.name = name
            self.version = version
        }
    }

    public struct SessionState: Sendable, Equatable {
        public var id: SessionId
        public var cwd: String
        public init(id: SessionId, cwd: String) {
            self.id = id
            self.cwd = cwd
        }
    }

    private struct ActiveSession {
        let client: any ChatBackend
        let cwd: String
        /// Identifies this specific registration. The pump task captures it and
        /// every fan-out/finish re-checks it against the live session, so a
        /// lingering pump from a since-closed backend (whose cooperative
        /// cancellation hasn't taken effect yet) can never write into a *newer*
        /// session that was re-opened under the same id — the iOS reconnect path
        /// (close → re-`openExisting`) does exactly that.
        let epoch: UUID
        var subscribers: [UUID: AsyncStream<HermesNotification>.Continuation] = [:]
        var pumpTask: Task<Void, Never>?
        /// Set when this session's notification stream ends while it's still
        /// registered — i.e. the underlying socket died but `close(id:)` was never
        /// called to tear it down. The live-chat `/api/ws` channel can die (gateway
        /// restart, channel reset) while the dashboard HTTP channel still answers,
        /// so a passing HTTP probe alone can't tell a dead chat from a live one;
        /// this flag does. Cleared implicitly by re-resume (close drops the session,
        /// the fresh `openExisting` registers a new `ActiveSession` with this false).
        var streamEnded = false
        /// Notifications that arrived while no subscriber was attached.
        /// Replayed in order to each new subscriber so resumed sessions
        /// actually surface their history — hermes streams the prior
        /// transcript as session updates *during* `session/load`, which
        /// completes before SessionsStore can construct the chat view's
        /// `LocalChatViewModel`. Without this buffer those updates fanned
        /// out to zero subscribers and got dropped.
        var replay: [HermesNotification] = []
    }

    /// Upper bound on the replay buffer so a multi-thousand-message session
    /// can't OOM us during a resume. Older entries are dropped first; the
    /// trade-off is the head of a very long transcript may scroll off.
    private static let replayCap = 10_000

    private let backendFactory: ChatBackendFactory
    private let clientInfo: ClientInfo
    private var sessions: [SessionId: ActiveSession] = [:]

    /// Each session boots whatever ``ChatBackend`` the factory returns (a
    /// ``GatewayChatClient`` over a ``GatewayWebSocket``).
    public init(
        clientInfo: ClientInfo = ClientInfo(),
        backendFactory: @escaping ChatBackendFactory
    ) {
        self.clientInfo = clientInfo
        self.backendFactory = backendFactory
    }

    public func openNew(cwd: String, mcpServers: [McpServer] = []) async throws -> SessionState {
        let client = try await bootClient()
        let response: NewSessionResponse
        do {
            HermesLog.session.info("openNew: sending session/new cwd=\(cwd, privacy: .public)")
            response = try await client.newSession(cwd: cwd, mcpServers: mcpServers)
            HermesLog.session.info("openNew: session/new ok id=\(response.sessionId, privacy: .public)")
        } catch {
            HermesLog.session.error("openNew: session/new failed: \(String(describing: error), privacy: .public)")
            await client.close()
            throw error
        }
        // Server-assigned ids should be unique, but defend against a
        // concurrent registration just in case (e.g. agent deduplicates).
        if sessions[response.sessionId] != nil {
            await client.close()
            throw SessionManagerError.duplicateSession(response.sessionId)
        }
        register(client: client, sessionId: response.sessionId, cwd: cwd)
        return SessionState(id: response.sessionId, cwd: cwd)
    }

    public func openExisting(
        id: SessionId,
        cwd: String,
        mcpServers: [McpServer] = []
    ) async throws -> SessionState {
        // Pre-await fast path; we re-check after the suspensions below since
        // a concurrent caller can slip in between this check and `register`.
        if sessions[id] != nil {
            throw SessionManagerError.duplicateSession(id)
        }
        let client = try await bootClient()
        do {
            _ = try await client.loadSession(sessionId: id, cwd: cwd, mcpServers: mcpServers)
        } catch {
            await client.close()
            throw error
        }
        // Post-await dedup is outside the do/catch so we don't double-close
        // the client through both the explicit cleanup and the catch path.
        if sessions[id] != nil {
            await client.close()
            throw SessionManagerError.duplicateSession(id)
        }
        register(client: client, sessionId: id, cwd: cwd)
        return SessionState(id: id, cwd: cwd)
    }

    public func client(for id: SessionId) -> (any ChatBackend)? {
        sessions[id]?.client
    }

    public func cwd(for id: SessionId) -> String? {
        sessions[id]?.cwd
    }

    public func activeSessions() -> [SessionState] {
        sessions.map { SessionState(id: $0.key, cwd: $0.value.cwd) }
    }

    /// Ids of still-registered sessions whose notification stream ended without a
    /// `close(id:)` — the live chat socket died while the session was meant to be
    /// alive. The iOS background→foreground recovery consults this after a passing
    /// HTTP probe to re-resume only the affected chats over the still-good tunnel.
    public func deadSessionIds() -> [SessionId] {
        sessions.compactMap { $0.value.streamEnded ? $0.key : nil }
    }

    public func notifications(for id: SessionId) -> AsyncStream<HermesNotification> {
        let token = UUID()
        var capturedContinuation: AsyncStream<HermesNotification>.Continuation!
        let stream = AsyncStream<HermesNotification> { continuation in
            capturedContinuation = continuation
        }
        capturedContinuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id: id, token: token) }
        }
        addSubscriber(id: id, token: token, continuation: capturedContinuation)
        return stream
    }

    public func close(id: SessionId) async {
        guard var active = sessions.removeValue(forKey: id) else {
            return
        }
        active.pumpTask?.cancel()
        for (_, continuation) in active.subscribers {
            continuation.finish()
        }
        active.subscribers.removeAll()
        await active.client.close()
    }

    public func closeAll() async {
        for id in Array(sessions.keys) {
            await close(id: id)
        }
    }

    private func bootClient() async throws -> any ChatBackend {
        HermesLog.session.info("bootClient: creating backend")
        let client = try await backendFactory()
        do {
            HermesLog.session.info("bootClient: starting backend")
            try await client.start(
                clientInfo: Implementation(name: clientInfo.name, version: clientInfo.version)
            )
            HermesLog.session.info("bootClient: backend started")
            return client
        } catch {
            HermesLog.session.error("bootClient: start failed: \(String(describing: error), privacy: .public)")
            await client.close()
            throw error
        }
    }

    private func register(client: any ChatBackend, sessionId: SessionId, cwd: String) {
        let epoch = UUID()
        var active = ActiveSession(client: client, cwd: cwd, epoch: epoch)
        active.pumpTask = Task { [weak self] in
            await self?.pump(sessionId: sessionId, epoch: epoch, notifications: client.notifications)
        }
        sessions[sessionId] = active
    }

    private func pump(
        sessionId: SessionId,
        epoch: UUID,
        notifications: AsyncThrowingStream<HermesNotification, Error>
    ) async {
        do {
            for try await notification in notifications {
                fanOut(sessionId: sessionId, epoch: epoch, notification: notification)
            }
        } catch {
            // Notification stream ended — fall through to finish subscribers.
        }
        // The stream ended. If this session is still registered (close() removes
        // it), the socket died out from under a session that should be live —
        // flag it so the store can re-resume just this chat. A close-driven exit
        // fails the epoch guard (the session is gone or re-registered) and no-ops.
        markStreamEnded(sessionId: sessionId, epoch: epoch)
        finishSubscribers(sessionId: sessionId, epoch: epoch)
    }

    private func markStreamEnded(sessionId: SessionId, epoch: UUID) {
        guard var active = sessions[sessionId], active.epoch == epoch else {
            return
        }
        active.streamEnded = true
        sessions[sessionId] = active
    }

    private func fanOut(sessionId: SessionId, epoch: UUID, notification: HermesNotification) {
        // Ignore a stale pump still draining a closed backend: if this id was
        // re-opened, the live session carries a different epoch and must not
        // inherit the dead session's notifications.
        guard var active = sessions[sessionId], active.epoch == epoch else {
            return
        }
        // Always buffer for replay so a late subscriber (e.g. a chat tab
        // opened after the session was registered) still sees the full
        // resumed transcript. The cap prevents an unbounded transcript
        // from growing memory without bound.
        active.replay.append(notification)
        if active.replay.count > Self.replayCap {
            active.replay.removeFirst(active.replay.count - Self.replayCap)
        }
        for (_, continuation) in active.subscribers {
            continuation.yield(notification)
        }
        sessions[sessionId] = active
    }

    private func finishSubscribers(sessionId: SessionId, epoch: UUID) {
        // Same stale-pump guard as `fanOut`: a dead backend's pump ending must
        // not finish the subscribers of a session re-opened under this id.
        guard var active = sessions[sessionId], active.epoch == epoch else {
            return
        }
        for (_, continuation) in active.subscribers {
            continuation.finish()
        }
        active.subscribers.removeAll()
        sessions[sessionId] = active
    }

    private func addSubscriber(
        id: SessionId,
        token: UUID,
        continuation: AsyncStream<HermesNotification>.Continuation
    ) {
        guard var active = sessions[id] else {
            continuation.finish()
            return
        }
        // Drain buffered history before registering so the new subscriber
        // observes notifications in send order. Replay even runs for the
        // very first subscriber — that's the resume-history path. Yielding
        // happens synchronously (AsyncStream uses an unbounded continuation
        // buffer by default), so this can't deadlock the actor.
        for notification in active.replay {
            continuation.yield(notification)
        }
        active.subscribers[token] = continuation
        sessions[id] = active
    }

    private func removeSubscriber(id: SessionId, token: UUID) {
        guard var active = sessions[id] else {
            return
        }
        active.subscribers.removeValue(forKey: token)
        sessions[id] = active
    }
}
