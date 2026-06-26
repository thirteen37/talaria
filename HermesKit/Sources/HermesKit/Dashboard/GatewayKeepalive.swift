import Foundation

/// Repeating keepalive ping for a live ``GatewayWebSocket`` backed by
/// `URLSessionWebSocketTask`.
///
/// URLSession applies `timeoutIntervalForRequest` (60s on `.default`) to the wait
/// for each *inbound* frame, so a healthy but quiet socket — a long-running tool
/// call mid-turn, a model thinking pause, or an idle session while the window is
/// unfocused — fails `receive()` with `NSURLErrorTimedOut` and tears the live chat
/// down mid-stream. Sending a ping every ~20s draws a server PONG, whose inbound
/// frame resets that idle timer, so a healthy connection never trips the timeout.
///
/// Isolated from the socket (rather than inlined) so its schedule and teardown are
/// unit-testable with a fake sender — `URLSessionWebSocketTask` has no public
/// initializer, so the ping action is injected. All state is confined to `queue`.
final class GatewayKeepalive: @unchecked Sendable {
    /// Sends one ping, invoking `pong` with the result (nil = healthy, non-nil =
    /// the socket is dead/half-open). Production wires this to
    /// `URLSessionWebSocketTask.sendPing(pongReceiveHandler:)`.
    typealias Send = @Sendable (_ pong: @escaping @Sendable (Error?) -> Void) -> Void

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let send: Send
    private let onFailure: @Sendable (Error) -> Void
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(
        interval: TimeInterval,
        queue: DispatchQueue,
        send: @escaping Send,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.send = send
        self.onFailure = onFailure
    }

    /// Begins the repeating ping. The first ping fires one interval out (well under
    /// the 60s receive timeout). Call once.
    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil, !self.stopped else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
            timer.setEventHandler { [weak self] in self?.fire() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops pinging. Idempotent and safe to call from any thread; once stopped no
    /// further ping or `onFailure` can fire.
    func stop() {
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }

    /// Timer handler — runs on `queue`.
    private func fire() {
        guard !stopped else { return }
        send { [weak self] error in
            guard let self, let error else { return }
            // The pong handler runs on URLSession's delegate queue; hop back to
            // `queue` so the stopped check and teardown stay serialized with
            // start/stop (no failure after a `stop()` that raced the in-flight ping).
            self.queue.async {
                guard !self.stopped else { return }
                // A failed ping means the socket is dead — stop pinging it (the
                // receive loop self-terminates on failure too; the keepalive must
                // as well, or it would re-ping + re-fail every interval until
                // `close()`, which the stranded-session case may never reach).
                // Tear down inline: we're already on `queue`, so calling `stop()`
                // would deadlock on its own `queue.sync`.
                self.stopped = true
                self.timer?.cancel()
                self.timer = nil
                self.onFailure(error)
            }
        }
    }
}
