import Foundation
import Testing
@testable import HermesKit

/// Unit tests for ``GatewayKeepalive`` — the repeating ping that keeps a healthy
/// idle `URLSessionWebSocketTask` from tripping URLSession's 60s receive timeout.
/// Driven with a short injected interval and a fake sender so the schedule and
/// teardown are deterministic without a live socket.
@Suite
struct GatewayKeepaliveTests {
    /// Records ping invocations and lets a test decide whether each one
    /// "succeeds" (pong, nil error) or fails (the socket is dead).
    private final class FakeSender: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private let failWith: Error?

        init(failWith: Error? = nil) {
            self.failWith = failWith
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }

        func send(_ pong: @escaping @Sendable (Error?) -> Void) {
            lock.lock(); _count += 1; lock.unlock()
            pong(failWith)
        }
    }

    @Test
    func pingsFireRepeatedlyOnSchedule() async throws {
        let sender = FakeSender()
        let keepalive = GatewayKeepalive(
            interval: 0.02,
            queue: DispatchQueue(label: "test.keepalive"),
            send: { sender.send($0) },
            onFailure: { _ in }
        )
        keepalive.start()
        // ~10 intervals of headroom; expect several pings to have fired.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sender.count >= 3)
        keepalive.stop()
    }

    @Test
    func stopHaltsFurtherPings() async throws {
        let sender = FakeSender()
        let keepalive = GatewayKeepalive(
            interval: 0.02,
            queue: DispatchQueue(label: "test.keepalive"),
            send: { sender.send($0) },
            onFailure: { _ in }
        )
        keepalive.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        keepalive.stop()
        let afterStop = sender.count
        // No more pings after stop, even after several more intervals elapse.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sender.count == afterStop)
    }

    @Test
    func failedPingInvokesOnFailureWithTheError() async throws {
        struct DeadSocket: Error {}
        let sender = FakeSender(failWith: DeadSocket())
        let failed = LockedFlag()
        let keepalive = GatewayKeepalive(
            interval: 0.02,
            queue: DispatchQueue(label: "test.keepalive"),
            send: { sender.send($0) },
            onFailure: { error in
                if error is DeadSocket { failed.set() }
            }
        )
        keepalive.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(failed.value)
        keepalive.stop()
    }

    @Test
    func stopsPingingAfterAFailedPing() async throws {
        // A failed ping means the socket is dead. The keepalive must tear its timer
        // down (like the receive loop) rather than keep re-pinging + re-failing every
        // interval until close() — which the stranded-session case may never reach.
        struct DeadSocket: Error {}
        let sender = FakeSender(failWith: DeadSocket())
        let keepalive = GatewayKeepalive(
            interval: 0.02,
            queue: DispatchQueue(label: "test.keepalive"),
            send: { sender.send($0) },
            onFailure: { _ in }
        )
        keepalive.start()
        // The first ping fires (~0.02s), fails, and tears the timer down.
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterFailure = sender.count
        #expect(afterFailure == 1)   // exactly one ping, then it stopped
        // No further pings even after many more intervals would have elapsed.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sender.count == afterFailure)
        keepalive.stop()
    }

    @Test
    func onFailureNeverFiresAfterStop() async throws {
        struct DeadSocket: Error {}
        let sender = FakeSender(failWith: DeadSocket())
        let failures = LockedCounter()
        let keepalive = GatewayKeepalive(
            interval: 0.02,
            queue: DispatchQueue(label: "test.keepalive"),
            send: { sender.send($0) },
            onFailure: { _ in failures.increment() }
        )
        keepalive.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        keepalive.stop()
        let afterStop = failures.value
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(failures.value == afterStop)
    }
}

/// Minimal thread-safe one-shot flag for assertions off the test actor.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Minimal thread-safe counter for assertions off the test actor.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
