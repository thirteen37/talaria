import Foundation
import os

/// ``GatewayWebSocket`` backed by `URLSessionWebSocketTask`. Used wherever the
/// dashboard is reachable over a real loopback socket — macOS local and the
/// `ssh -L` remote forward (both `http://127.0.0.1:<port>`). iOS's NIO-SSH path
/// can't use this (no local socket) and gets `NIOSSHGatewayWebSocket`.
///
/// Uses a **delegate-backed** `URLSession` (not `URLSession.shared`) so the
/// handshake outcome is observable: `URLSession.shared` neither calls WebSocket
/// delegate methods nor populates `task.response`, which is why a rejected
/// upgrade only ever surfaced as an opaque `-1011 "bad response from the server"`.
/// With the delegate we log the HTTP status / close code the server returned —
/// see `HermesLog.gateway` (visible in macOS Console.app under the
/// `com.talaria.hermeskit` `gateway` category).
public final class URLSessionGatewayWebSocket: NSObject, GatewayWebSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    public nonisolated let messages: AsyncThrowingStream<Data, Error>

    private var task: URLSessionWebSocketTask!
    private var urlSession: URLSession!
    private let ownsSession: Bool
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stateQueue = DispatchQueue(label: "URLSessionGatewayWebSocket.state")
    private let redactedURL: String
    private var receiveStarted = false
    private var closed = false
    /// HTTP status the server returned on a *rejected* upgrade (>= 300), captured
    /// by the delegate (`task.response`) so the stream error can name it. A
    /// successful upgrade is `101`/2xx and is never stored here.
    private var handshakeStatus: Int?
    /// The real WebSocket close code (e.g. `1001` "going away"), captured by the
    /// delegate's `didCloseWith`. Preferred over the handshake status when a
    /// successful socket later drops, so logs read `code=1001` not `HTTP 101`.
    private var closeCode: Int?
    /// Active ping/PONG liveness probe (see ``GatewayKeepalive``). With this
    /// socket's OS idle timeout disabled (see ``init(url:session:pingInterval:)``),
    /// the keepalive is the *only* detector of a dead/half-open connection.
    /// Cancelled in ``close()``.
    private var keepalive: GatewayKeepalive?

    /// Build the `ws://…/api/ws?<credential>` URL from the dashboard's base
    /// (`http://127.0.0.1:<port>`) and the auth credential, then open the socket.
    public convenience init(
        dashboardBaseURL: URL,
        credential: GatewayCredential,
        session: URLSession? = nil,
        path: String = "/api/ws"
    ) throws {
        guard let url = Self.makeWebSocketURL(base: dashboardBaseURL, credential: credential, path: path) else {
            throw GatewayWebSocketError.notConnected
        }
        self.init(url: url, session: session)
    }

    /// - Parameters:
    ///   - session: injected only by tests; production passes `nil` so we build a
    ///     delegate-backed session (required to observe the handshake) whose idle
    ///     timeouts are disabled (see below).
    ///   - pingInterval: keepalive cadence. Default 20s. The keepalive
    ///     (``GatewayKeepalive``) is an active ping/PONG liveness probe — it does
    ///     **not** rely on the ping nudging any OS idle timer (that premise is
    ///     unverified and was the suspected cause of mid-stream truncation).
    ///     Injectable for tests.
    public init(url: URL, session: URLSession? = nil, pingInterval: TimeInterval = 20) {
        self.redactedURL = Self.redact(url)
        self.ownsSession = (session == nil)

        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.messages = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.continuation = captured!

        super.init()

        self.urlSession = session ?? URLSession(configuration: Self.longLivedConfiguration(), delegate: self, delegateQueue: nil)
        self.task = urlSession.webSocketTask(with: url)
        HermesLog.gateway.info("connecting \(self.redactedURL, privacy: .public)")
        task.resume()
        startReceiveLoop()
        startKeepalive(interval: pingInterval)
    }

    /// Configuration for the long-lived chat socket. Built from `.default` but
    /// with the per-request / per-resource idle timeouts pushed effectively to
    /// infinity: `timeoutIntervalForRequest` (60s on `.default`) otherwise applies
    /// to the wait for *each inbound frame*, so a healthy-but-quiet socket (a long
    /// tool call, a thinking pause, an unfocused idle session) trips
    /// `NSURLErrorTimedOut` and the live chat truncates mid-stream. Liveness is
    /// instead owned by ``GatewayKeepalive``'s active ping/PONG probe, so the OS
    /// idle timer is taken out of the teardown path entirely.
    static func longLivedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .greatestFiniteMagnitude
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        return config
    }

    /// Starts the repeating keepalive ping on ``stateQueue`` (the same queue that
    /// serializes `closed`). The keepalive is an active liveness probe: after
    /// ``GatewayKeepalive/maxMisses`` consecutive missing PONGs / ping errors it
    /// tears the stream down the same way ``receiveNext()``'s failure branch does.
    /// Since this socket's OS idle timeout is disabled (see
    /// ``longLivedConfiguration()``), the keepalive is the sole detector of a
    /// dead/half-open connection.
    private func startKeepalive(interval: TimeInterval) {
        let keepalive = GatewayKeepalive(
            interval: interval,
            queue: stateQueue,
            send: { [weak self] pong in self?.task.sendPing(pongReceiveHandler: pong) },
            onFailure: { [weak self] error in self?.handlePingFailure(error) }
        )
        self.keepalive = keepalive
        keepalive.start()
    }

    /// Invoked on ``stateQueue`` when a keepalive ping fails. Guards on `closed`
    /// (a close races the in-flight ping) and finishes the stream with the error,
    /// matching the `receiveNext` failure teardown.
    private func handlePingFailure(_ error: Error) {
        guard !closed else { return }
        HermesLog.gateway.error("keepalive ping failed: \(error.localizedDescription, privacy: .public) (\((error as NSError).code, privacy: .public)) for \(self.redactedURL, privacy: .public)")
        continuation.finish(throwing: error)
    }

    /// Maps an `http(s)://host:port` dashboard base to the matching
    /// `ws(s)://host:port<path>?<credential>`.
    static func makeWebSocketURL(base: URL, credential: GatewayCredential, path: String = "/api/ws") -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.path = path
        components.queryItems = [URLQueryItem(name: credential.queryName, value: credential.value)]
        return components.url
    }

    /// Redact the credential value from a URL for logging.
    static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.queryItems = components.queryItems?.map {
            URLQueryItem(name: $0.name, value: ($0.value?.isEmpty == false) ? "<redacted>" : $0.value)
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    public func send(_ data: Data) async throws {
        guard !stateQueue.sync(execute: { closed }) else { throw GatewayWebSocketError.closed }
        do {
            // The gateway speaks JSON text frames (json-rpc-gateway.ts).
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            throw GatewayWebSocketError.sendFailed(error.localizedDescription)
        }
    }

    public func close() async {
        let alreadyClosed = stateQueue.sync { () -> Bool in
            if closed { return true }
            closed = true
            return false
        }
        guard !alreadyClosed else { return }
        keepalive?.stop()
        task.cancel(with: .goingAway, reason: nil)
        // Break the URLSession→delegate(self) retain so we deallocate.
        if ownsSession { urlSession.invalidateAndCancel() }
        continuation.finish()
    }

    private func startReceiveLoop() {
        let alreadyStarted = stateQueue.sync { () -> Bool in
            if receiveStarted { return true }
            receiveStarted = true
            return false
        }
        guard !alreadyStarted else { return }
        receiveNext()
    }

    /// Recursive receive: `URLSessionWebSocketTask.receive()` delivers one
    /// message per call, so we re-arm after each frame until it throws (close).
    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .data(data):
                    self.continuation.yield(data)
                case let .string(text):
                    self.continuation.yield(Data(text.utf8))
                @unknown default:
                    break
                }
                self.receiveNext()
            case let .failure(error):
                let wasClosed = self.stateQueue.sync { self.closed }
                guard !wasClosed else {
                    self.continuation.finish(throwing: nil)
                    return
                }
                // The socket is dead — stop the keepalive, symmetric with the
                // ping-failure path (`GatewayKeepalive.fire()`), so a known-dead
                // socket isn't pinged for up to one more interval before its next
                // ping fails. Idempotent if the ping path already self-terminated.
                self.keepalive?.stop()
                // Classify the failure: a real close code (e.g. 1001 going away)
                // is preferred over the handshake status, and a *successful*
                // upgrade (101/2xx) is never mistaken for a rejection — so logs
                // and the stream error name the true cause.
                let handshakeStatus = self.stateQueue.sync { self.handshakeStatus }
                    ?? (self.task.response as? HTTPURLResponse)?.statusCode
                let closeCode = self.stateQueue.sync { self.closeCode }
                switch Self.classifyReceiveFailure(handshakeStatus: handshakeStatus, closeCode: closeCode) {
                case let .closeCode(code):
                    HermesLog.gateway.error("receive failed; closed code=\(code, privacy: .public) for \(self.redactedURL, privacy: .public)")
                    self.continuation.finish(throwing: GatewayWebSocketError.closedWithCode(code))
                case let .handshakeRejected(status):
                    HermesLog.gateway.error("receive failed; handshake HTTP \(status, privacy: .public) for \(self.redactedURL, privacy: .public)")
                    self.continuation.finish(throwing: GatewayWebSocketError.closedWithCode(status))
                case .underlying:
                    HermesLog.gateway.error("receive failed: \(error.localizedDescription, privacy: .public) (\((error as NSError).code, privacy: .public)) for \(self.redactedURL, privacy: .public)")
                    self.continuation.finish(throwing: error)
                }
            }
        }
    }

    /// What a receive-loop failure should finish the stream with.
    enum CloseClassification: Equatable {
        /// A real WebSocket close frame (e.g. `1001` going away).
        case closeCode(Int)
        /// A real upgrade rejection — the server answered the handshake with an
        /// HTTP error (>= 300).
        case handshakeRejected(Int)
        /// Neither: surface the raw transport error. Covers a *successful* upgrade
        /// (`101`/2xx) that later dropped without a close frame.
        case underlying
    }

    /// Pure classification so the close-diagnostics logic is unit-testable without
    /// a live socket. A real close code wins; a handshake status only counts as a
    /// rejection when it's an HTTP error (>= 300), so `101`/2xx are never
    /// misreported as rejections.
    static func classifyReceiveFailure(handshakeStatus: Int?, closeCode: Int?) -> CloseClassification {
        if let closeCode { return .closeCode(closeCode) }
        if let handshakeStatus, handshakeStatus >= 300 { return .handshakeRejected(handshakeStatus) }
        return .underlying
    }

    // MARK: - URLSession delegate (diagnostics)

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        HermesLog.gateway.info("handshake OK (101) for \(self.redactedURL, privacy: .public)")
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        stateQueue.sync { self.closeCode = Int(closeCode.rawValue) }
        HermesLog.gateway.error("closed code=\(closeCode.rawValue, privacy: .public) reason=\(text, privacy: .public)")
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Only a real HTTP error (>= 300) is an upgrade *rejection*. A successful
        // upgrade reports `101` (and 2xx responses are also success) — recording
        // those as a rejection would mask the true close reason (e.g. 1001).
        if let http = task.response as? HTTPURLResponse, http.statusCode >= 300 {
            stateQueue.sync { self.handshakeStatus = http.statusCode }
            let server = (http.allHeaderFields["Server"] as? String) ?? "?"
            HermesLog.gateway.error("upgrade rejected: HTTP \(http.statusCode, privacy: .public) server=\(server, privacy: .public) for \(self.redactedURL, privacy: .public)")
        }
        if let error {
            let ns = error as NSError
            HermesLog.gateway.error("task completed with error \(ns.domain, privacy: .public)/\(ns.code, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
