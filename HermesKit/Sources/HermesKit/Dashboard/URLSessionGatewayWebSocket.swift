import Foundation

/// ``GatewayWebSocket`` backed by `URLSessionWebSocketTask`. Used wherever the
/// dashboard is reachable over a real loopback socket — macOS local and the
/// `ssh -L` remote forward (both `http://127.0.0.1:<port>`). iOS's NIO-SSH path
/// can't use this (no local socket) and gets its own impl in Phase 3.
public final class URLSessionGatewayWebSocket: GatewayWebSocket, @unchecked Sendable {
    public nonisolated let messages: AsyncThrowingStream<Data, Error>

    private let task: URLSessionWebSocketTask
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stateQueue = DispatchQueue(label: "URLSessionGatewayWebSocket.state")
    private var receiveStarted = false
    private var closed = false

    /// Build the `ws://…/api/ws?token=…` URL from the dashboard's base
    /// (`http://127.0.0.1:<port>`) and session token, then open the socket.
    public convenience init(
        dashboardBaseURL: URL,
        token: String?,
        session: URLSession = .shared,
        path: String = "/api/ws"
    ) throws {
        guard let url = Self.makeWebSocketURL(base: dashboardBaseURL, token: token, path: path) else {
            throw GatewayWebSocketError.notConnected
        }
        self.init(url: url, session: session)
    }

    public init(url: URL, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: url)

        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.messages = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.continuation = captured!

        task.resume()
        startReceiveLoop()
    }

    /// Maps an `http(s)://host:port` dashboard base to the matching
    /// `ws(s)://host:port<path>?token=…`.
    static func makeWebSocketURL(base: URL, token: String?, path: String = "/api/ws") -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https", "wss": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.path = path
        if let token {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components.url
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
                self.continuation.finish(throwing: wasClosed ? nil : error)
            }
        }
    }
}
