import Foundation

public enum SessionManagerError: Error, Equatable, Sendable {
    case sessionNotFound(SessionId)
    case duplicateSession(SessionId)
}

public actor SessionManager {
    public typealias TransportFactory = @Sendable () async throws -> any Transport

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
        let client: HermesClient
        let cwd: String
        var subscribers: [UUID: AsyncStream<HermesNotification>.Continuation] = [:]
        var pumpTask: Task<Void, Never>?
    }

    private let transportFactory: TransportFactory
    private let clientInfo: ClientInfo
    private var sessions: [SessionId: ActiveSession] = [:]

    public init(
        clientInfo: ClientInfo = ClientInfo(),
        transportFactory: @escaping TransportFactory
    ) {
        self.transportFactory = transportFactory
        self.clientInfo = clientInfo
    }

    public func openNew(cwd: String, mcpServers: [McpServer] = []) async throws -> SessionState {
        let client = try await bootClient()
        let response: NewSessionResponse
        do {
            response = try await client.newSession(cwd: cwd, mcpServers: mcpServers)
        } catch {
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

    public func client(for id: SessionId) -> HermesClient? {
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

    private func bootClient() async throws -> HermesClient {
        let transport = try await transportFactory()
        let client = HermesClient(transport: transport)
        do {
            _ = try await client.initialize(
                clientInfo: Implementation(name: clientInfo.name, version: clientInfo.version)
            )
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    private func register(client: HermesClient, sessionId: SessionId, cwd: String) {
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
        guard let active = sessions[sessionId] else {
            return
        }
        for (_, continuation) in active.subscribers {
            continuation.yield(notification)
        }
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
