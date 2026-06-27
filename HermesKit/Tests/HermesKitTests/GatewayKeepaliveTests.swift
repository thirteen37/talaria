import Foundation
import Testing
@testable import HermesKit

/// Unit tests for ``GatewayKeepalive`` — the active ping/PONG liveness probe that
/// detects a dead or half-open chat socket once URLSession's OS idle timeout is
/// disabled for the long-lived connection. Driven with a short injected interval
/// and a scriptable fake sender so the schedule, deadline, and transient
/// tolerance are deterministic without a live socket.
@Suite
struct GatewayKeepaliveTests {
    /// Scriptable ping sender. Records invocations and decides, per call, whether
    /// to deliver a PONG (`nil`), a write error, or nothing at all (the half-open
    /// case, where `URLSessionWebSocketTask` never invokes the handler).
    private final class FakeSender: @unchecked Sendable {
        enum Behavior {
            /// Healthy: a PONG returns on every ping.
            case alwaysPong
            /// Half-open socket: the handler is never invoked.
            case neverRespond
            /// Every ping write fails with this error.
            case alwaysFail(Error)
            /// The first `count` ping writes fail; subsequent pings PONG cleanly.
            case failFirst(count: Int, Error)
        }

        private let lock = NSLock()
        private var _count = 0
        private let behavior: Behavior

        init(_ behavior: Behavior) {
            self.behavior = behavior
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }

        func send(_ pong: @escaping @Sendable (Error?) -> Void) {
            lock.lock(); _count += 1; let n = _count; lock.unlock()
            switch behavior {
            case .alwaysPong: pong(nil)
            case .neverRespond: break
            case let .alwaysFail(error): pong(error)
            case let .failFirst(count, error): pong(n <= count ? error : nil)
            }
        }
    }

    private func makeKeepalive(
        _ sender: FakeSender,
        interval: TimeInterval = 0.02,
        maxMisses: Int = 2,
        onFailure: @escaping @Sendable (Error) -> Void = { _ in }
    ) -> GatewayKeepalive {
        GatewayKeepalive(
            interval: interval,
            maxMisses: maxMisses,
            queue: DispatchQueue(label: "test.keepalive"),
            send: { sender.send($0) },
            onFailure: onFailure
        )
    }

    // MARK: - Scheduling

    @Test
    func pingsFireRepeatedlyOnSchedule() async throws {
        let sender = FakeSender(.alwaysPong)
        let keepalive = makeKeepalive(sender)
        keepalive.start()
        // ~10 intervals of headroom; expect several pings to have fired.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sender.count >= 3)
        keepalive.stop()
    }

    @Test
    func stopHaltsFurtherPings() async throws {
        let sender = FakeSender(.alwaysPong)
        let keepalive = makeKeepalive(sender)
        keepalive.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        keepalive.stop()
        let afterStop = sender.count
        // No more pings after stop, even after several more intervals elapse.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sender.count == afterStop)
    }

    // MARK: - Liveness (fix B)

    @Test
    func healthyPongStreamNeverFails() async throws {
        // A socket that PONGs every ping is alive — onFailure must never fire,
        // however long it runs.
        let sender = FakeSender(.alwaysPong)
        let failed = LockedFlag()
        let keepalive = makeKeepalive(sender, onFailure: { _ in failed.set() })
        keepalive.start()
        try await Task.sleep(nanoseconds: 200_000_000)   // ~10 intervals
        #expect(!failed.value)
        keepalive.stop()
    }

    @Test
    func halfOpenSocketFailsAfterDeadlineNotBefore() async throws {
        // A half-open tunnel never invokes the ping handler. The keepalive must
        // detect it via the missing-PONG deadline (maxMisses consecutive misses),
        // not earlier. With maxMisses=2 the fires go: ping #1 sent (outstanding);
        // fire #2 counts miss #1 and sends ping #2; fire #3 counts miss #2 and
        // trips the deadline — tearing down *before* it sends, so exactly
        // `maxMisses` (2) pings ever went out and failure lands on the
        // (maxMisses + 1)-th fire (≈ maxMisses intervals after the socket died).
        let sender = FakeSender(.neverRespond)
        let failed = LockedFlag()
        let countAtFailure = LockedBox<Int>()
        let keepalive = makeKeepalive(sender, maxMisses: 2, onFailure: { _ in
            countAtFailure.set(sender.count)
            failed.set()
        })
        keepalive.start()
        try await Task.sleep(nanoseconds: 300_000_000)   // many intervals
        #expect(failed.value)
        #expect(countAtFailure.value == 2)   // maxMisses pings sent, then deadline tripped
        keepalive.stop()
    }

    @Test
    func halfOpenFailureReportsUnresponsive() async throws {
        // The timeout path has no underlying NSError, so it reports the synthetic
        // `GatewayKeepaliveError.unresponsive`.
        let sender = FakeSender(.neverRespond)
        let sawUnresponsive = LockedFlag()
        let keepalive = makeKeepalive(sender, maxMisses: 2, onFailure: { error in
            if case GatewayKeepaliveError.unresponsive = error { sawUnresponsive.set() }
        })
        keepalive.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(sawUnresponsive.value)
        keepalive.stop()
    }

    // MARK: - Transient tolerance (fix C)

    @Test
    func singleTransientPingErrorIsTolerated() async throws {
        // One write error followed by recovery must NOT tear the socket down — the
        // old design killed it on the first error. With maxMisses=2 the single
        // miss is absorbed and the next clean PONG resets the streak.
        let sender = FakeSender(.failFirst(count: 1, DeadSocket()))
        let failed = LockedFlag()
        let keepalive = makeKeepalive(sender, maxMisses: 2, onFailure: { _ in failed.set() })
        keepalive.start()
        try await Task.sleep(nanoseconds: 200_000_000)   // ~10 intervals
        #expect(!failed.value)
        #expect(sender.count >= 3)   // it kept pinging after the blip
        keepalive.stop()
    }

    @Test
    func consecutivePingErrorsFailWithTheError() async throws {
        // maxMisses consecutive write errors are a genuinely dead socket — fail,
        // surfacing the underlying error (not the synthetic unresponsive one).
        let sender = FakeSender(.alwaysFail(DeadSocket()))
        let sawDeadSocket = LockedFlag()
        let keepalive = makeKeepalive(sender, maxMisses: 2, onFailure: { error in
            if error is DeadSocket { sawDeadSocket.set() }
        })
        keepalive.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(sawDeadSocket.value)
        keepalive.stop()
    }

    @Test
    func stopsPingingAfterTeardown() async throws {
        // Once the deadline trips and onFailure fires, the timer is torn down — no
        // further pings (which the stranded-session case would otherwise emit every
        // interval until close()).
        let sender = FakeSender(.alwaysFail(DeadSocket()))
        let keepalive = makeKeepalive(sender, maxMisses: 2)
        keepalive.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterTeardown = sender.count
        #expect(afterTeardown == 2)   // exactly maxMisses pings, then it stopped
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(sender.count == afterTeardown)
        keepalive.stop()
    }

    @Test
    func onFailureNeverFiresAfterStop() async throws {
        let sender = FakeSender(.alwaysFail(DeadSocket()))
        let failures = LockedCounter()
        let keepalive = makeKeepalive(sender, maxMisses: 2, onFailure: { _ in failures.increment() })
        keepalive.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        keepalive.stop()
        let afterStop = failures.value
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(failures.value == afterStop)
    }
}

private struct DeadSocket: Error {}

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

/// Minimal thread-safe one-shot box capturing a value observed off the test actor.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.lock(); if stored == nil { stored = value }; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}
