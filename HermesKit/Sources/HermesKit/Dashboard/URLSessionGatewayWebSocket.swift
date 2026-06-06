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
/// see `HermesLog.gateway` (visible in the in-app log console).
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
    /// HTTP status the server returned on a rejected upgrade, captured by the
    /// delegate (`task.response`) so the stream error can name it.
    private var handshakeStatus: Int?

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

    /// - Parameter session: injected only by tests; production passes `nil` so we
    ///   build a delegate-backed session (required to observe the handshake).
    public init(url: URL, session: URLSession? = nil) {
        self.redactedURL = Self.redact(url)
        self.ownsSession = (session == nil)

        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.messages = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.continuation = captured!

        super.init()

        self.urlSession = session ?? URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.task = urlSession.webSocketTask(with: url)
        HermesLog.gateway.info("connecting \(self.redactedURL, privacy: .public)")
        task.resume()
        startReceiveLoop()
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
                // Prefer the HTTP status the delegate captured from the rejected
                // upgrade; fall back to the task.response, then the raw error.
                let status = self.stateQueue.sync { self.handshakeStatus }
                    ?? (self.task.response as? HTTPURLResponse)?.statusCode
                if let status, !(200..<300).contains(status) {
                    HermesLog.gateway.error("receive failed; handshake HTTP \(status, privacy: .public) for \(self.redactedURL, privacy: .public)")
                    self.continuation.finish(throwing: GatewayWebSocketError.closedWithCode(status))
                } else {
                    HermesLog.gateway.error("receive failed: \(error.localizedDescription, privacy: .public) (\((error as NSError).code, privacy: .public)) for \(self.redactedURL, privacy: .public)")
                    self.continuation.finish(throwing: error)
                }
            }
        }
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
        HermesLog.gateway.error("closed code=\(closeCode.rawValue, privacy: .public) reason=\(text, privacy: .public)")
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse {
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
