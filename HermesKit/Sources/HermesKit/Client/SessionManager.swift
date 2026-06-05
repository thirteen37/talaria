import Foundation

public enum SessionManagerError: Error, Equatable, Sendable {
    case sessionNotFound(SessionId)
    case duplicateSession(SessionId)
}

public actor SessionManager {
    public typealias TransportFactory = @Sendable () async throws -> any Transport
    /// Produces a fresh, un-started ``ChatBackend`` per session. `SessionManager`
    /// calls ``ChatBackend/start(clientInfo:)`` on it before creating/loading a
    /// session. ACP wraps a ``Transport`` into a ``HermesClient``; the WebSocket
    /// path returns a ``GatewayChatClient``.
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
        var subscribers: [UUID: AsyncStream<HermesNotification>.Continuation] = [:]
        var pumpTask: Task<Void, Never>?
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

    /// ACP backend: each session boots a ``HermesClient`` over a fresh
    /// ``Transport`` from `transportFactory`.
    public init(
        clientInfo: ClientInfo = ClientInfo(),
        transportFactory: @escaping TransportFactory
    ) {
        self.clientInfo = clientInfo
        self.backendFactory = { HermesClient(transport: try await transportFactory()) }
    }

    /// Generic backend: each session boots whatever ``ChatBackend`` the factory
    /// returns (e.g. a ``GatewayChatClient`` over a ``GatewayWebSocket``).
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
        var active = ActiveSession(client: client, cwd: cwd)
        active.pumpTask = Task { [weak self] in
            await self?.pump(sessionId: sessionId, notifications: client.notifications)
        }
        sessions[sessionId] = active
    }

    private func pump(
        sessionId: SessionId,
        notifications: AsyncThrowingStream<HermesNotification, Error>
    ) async {
        do {
            for try await notification in notifications {
                fanOut(sessionId: sessionId, notification: notification)
            }
        } catch {
            // Notification stream ended — fall through to finish subscribers.
        }
        finishSubscribers(sessionId: sessionId)
    }

    private func fanOut(sessionId: SessionId, notification: HermesNotification) {
        guard var active = sessions[sessionId] else {
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

    private func finishSubscribers(sessionId: SessionId) {
        guard var active = sessions[sessionId] else {
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
