import Foundation

/// Reason a ``GatewayKeepalive`` gave up on a socket. Used for the timeout path
/// (a ping whose PONG never returned), where there is no underlying `NSError`.
enum GatewayKeepaliveError: Error, LocalizedError {
    /// `count` consecutive keepalive pings drew no PONG (and no write error) —
    /// the classic half-open SSH tunnel: writes buffer locally, nothing returns.
    case unresponsive(count: Int)

    var errorDescription: String? {
        switch self {
        case let .unresponsive(count):
            return "keepalive: no PONG after \(count) consecutive pings (socket half-open?)"
        }
    }
}

/// Active liveness probe for a live ``GatewayWebSocket`` backed by
/// `URLSessionWebSocketTask`.
///
/// The macOS WS transport disables URLSession's per-`receive()` idle timeout
/// (`timeoutIntervalForRequest`) for this long-lived socket, so a healthy but
/// quiet connection — a long-running tool call mid-turn, a model thinking pause,
/// or an idle session while the window is unfocused — is never torn down by the
/// OS just for being silent. With that backstop gone, this keepalive becomes the
/// *only* thing that detects a dead or half-open socket, so it is a real
/// ping/PONG liveness probe rather than a timer-nudge:
///
/// - Every `interval` it sends one ping and remembers it is *outstanding*.
/// - A returned PONG (the `send` callback firing with `nil`) clears the
///   outstanding ping and resets the miss streak — the socket is alive.
/// - A ping whose callback never fires by the next interval (the half-open
///   tunnel: the write buffers locally, no frame ever returns) counts as a
///   **miss**. A write *error* on the ping (callback fires with an error) also
///   counts as a miss — but as just *one* miss, so a single transient blip no
///   longer tears down an otherwise healthy socket.
/// - After ``maxMisses`` *consecutive* misses (≈ `maxMisses` × `interval` of
///   silence) it calls `onFailure`, which tears the stream down the same way
///   ``URLSessionGatewayWebSocket``'s receive-failure branch does.
///
/// Isolated from the socket (rather than inlined) so its schedule and teardown
/// are unit-testable with a fake sender — `URLSessionWebSocketTask` has no public
/// initializer, so the ping action is injected. All state is confined to `queue`.
final class GatewayKeepalive: @unchecked Sendable {
    /// Sends one ping, invoking `pong` with the result: `nil` = a PONG returned
    /// (healthy), non-nil = the ping write failed. A half-open socket invokes the
    /// callback with *neither* — it simply never fires, which the deadline logic
    /// catches at the next interval. Production wires this to
    /// `URLSessionWebSocketTask.sendPing(pongReceiveHandler:)`.
    typealias Send = @Sendable (_ pong: @escaping @Sendable (Error?) -> Void) -> Void

    private let interval: TimeInterval
    /// Consecutive misses (missing PONG or ping write error) that trip a teardown.
    /// Default 2 — tolerates one transient blip while still catching a genuinely
    /// dead socket within ~`maxMisses` intervals.
    private let maxMisses: Int
    private let queue: DispatchQueue
    private let send: Send
    private let onFailure: @Sendable (Error) -> Void
    private var timer: DispatchSourceTimer?
    private var stopped = false

    /// Whether a ping is in flight whose `send` callback has not yet fired. If it
    /// is still true at the next `fire()`, that ping drew no PONG — a miss.
    private var outstanding = false
    /// Consecutive misses since the last successful PONG.
    private var missCount = 0

    init(
        interval: TimeInterval,
        maxMisses: Int = 2,
        queue: DispatchQueue,
        send: @escaping Send,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.interval = interval
        self.maxMisses = max(1, maxMisses)
        self.queue = queue
        self.send = send
        self.onFailure = onFailure
    }

    /// Begins the repeating ping. The first ping fires one interval out. Call once.
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

        // The previous ping is still outstanding a full interval later: no PONG
        // and no write error came back. That's the half-open case the now-disabled
        // OS idle timeout used to catch — count it as a miss.
        if outstanding {
            outstanding = false
            recordMiss(GatewayKeepaliveError.unresponsive(count: missCount + 1))
            guard !stopped else { return }   // recordMiss may have torn down
        }

        outstanding = true
        send { [weak self] error in
            guard let self else { return }
            // The pong handler runs on URLSession's delegate queue; hop back to
            // `queue` so every state mutation stays serialized with start/stop and
            // the timer (no failure after a `stop()` that raced the in-flight ping).
            self.queue.async {
                // Ignore a stale callback (e.g. a late PONG after we already
                // counted this ping as missed and armed a new one).
                guard !self.stopped, self.outstanding else { return }
                self.outstanding = false
                if let error {
                    // A ping write failure — fold it into the same miss counter so
                    // one transient blip is tolerated (we only tear down after
                    // `maxMisses` consecutive misses).
                    self.recordMiss(error)
                } else {
                    // A PONG returned: the socket is alive. Reset the miss streak.
                    self.missCount = 0
                }
            }
        }
    }

    /// Records one liveness miss (a missing PONG or a ping write error). On the
    /// `maxMisses`-th consecutive miss, tears the timer down and reports `error`.
    /// Must run on `queue`. Torn down inline (not via `stop()`) because we are
    /// already on `queue` and `stop()`'s `queue.sync` would deadlock.
    private func recordMiss(_ error: Error) {
        missCount += 1
        guard missCount >= maxMisses else { return }
        stopped = true
        timer?.cancel()
        timer = nil
        onFailure(error)
    }
}
