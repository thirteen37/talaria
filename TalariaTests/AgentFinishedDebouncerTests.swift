import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the coalescing logic that fixes the early "agent finished" fire:
/// across Hermes' chained `message.start … message.complete` continuation turns
/// the debouncer must fire exactly once, only after the final clean end settles,
/// and never for an unclean (interrupted/error) end or an unarmed session.
@MainActor
@Suite
struct AgentFinishedDebouncerTests {
    /// A short grace keeps the tests fast while still exercising the debounce.
    private static let grace: Duration = .milliseconds(40)

    private final class FireSpy {
        private(set) var fired: [SessionId] = []
        func record(_ id: SessionId) { fired.append(id) }
    }

    private func makeDebouncer() -> (AgentFinishedDebouncer, FireSpy) {
        let spy = FireSpy()
        let debouncer = AgentFinishedDebouncer(grace: Self.grace) { id in
            spy.record(id)
        }
        return (debouncer, spy)
    }

    /// Waits past the grace window so any scheduled fire has run.
    private func waitPastGrace() async throws {
        try await Task.sleep(for: Self.grace * 3)
    }

    @Test
    func firesOnceAfterChainedContinuations() async throws {
        // The repro: a user turn, then a chained continuation. The first clean end
        // schedules a fire; the continuation's start cancels it; its end reschedules.
        // Net result is a single fire, after the *last* end + grace.
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")

        debouncer.turnStarted(id: "s")
        debouncer.turnEnded(id: "s", clean: true)   // first complete (mid-burst)
        debouncer.turnStarted(id: "s")              // continuation begins
        debouncer.turnEnded(id: "s", clean: true)   // continuation ends

        try await waitPastGrace()
        #expect(spy.fired == ["s"])
    }

    @Test
    func doesNotFireBeforeGraceElapses() async throws {
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")
        debouncer.turnEnded(id: "s", clean: true)

        // Immediately after the end, before the grace window — nothing fired yet.
        #expect(spy.fired.isEmpty)
        try await waitPastGrace()
        #expect(spy.fired == ["s"])
    }

    @Test
    func aNewTurnDuringGraceHoldsTheNotification() async throws {
        // A continuation that starts within the grace window must cancel the
        // pending fire so it doesn't land at the start of the continuation's text.
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")
        debouncer.turnEnded(id: "s", clean: true)
        debouncer.turnStarted(id: "s")   // continuation begins before grace elapsed

        try await waitPastGrace()
        // Held: the continuation never ended, so no fire.
        #expect(spy.fired.isEmpty)
    }

    @Test
    func uncleanEndNeverFiresAndDisarms() async throws {
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")
        debouncer.turnEnded(id: "s", clean: false)   // interrupted / error
        try await waitPastGrace()
        #expect(spy.fired.isEmpty)

        // The unclean end also disarmed: a later turn on the same session that
        // ends cleanly (e.g. an autonomous continuation) stays suppressed, since
        // arming requires a fresh user send.
        debouncer.turnStarted(id: "s")
        debouncer.turnEnded(id: "s", clean: true)
        try await waitPastGrace()
        #expect(spy.fired.isEmpty)
    }

    @Test
    func uncleanEndDuringGraceCancelsAPendingFire() async throws {
        // A clean end schedules a fire; a follow-up unclean end (e.g. the user
        // cancels the continuation) must cancel it.
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")
        debouncer.turnEnded(id: "s", clean: true)
        debouncer.turnStarted(id: "s")
        debouncer.turnEnded(id: "s", clean: false)

        try await waitPastGrace()
        #expect(spy.fired.isEmpty)
    }

    @Test
    func unarmedSessionNeverFires() async throws {
        // A purely autonomous turn the user never triggered (no arm) must not
        // notify, even on a clean end.
        let (debouncer, spy) = makeDebouncer()
        debouncer.turnStarted(id: "s")
        debouncer.turnEnded(id: "s", clean: true)

        try await waitPastGrace()
        #expect(spy.fired.isEmpty)
    }

    @Test
    func disarmsAfterFiringSoTheNextTurnNeedsReArming() async throws {
        // Firing consumes the arm: a later autonomous turn on the same session
        // (no new user send) must not piggyback a second notification.
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")
        debouncer.turnEnded(id: "s", clean: true)
        try await waitPastGrace()
        #expect(spy.fired == ["s"])

        // A new autonomous turn without re-arming: no further fire.
        debouncer.turnStarted(id: "s")
        debouncer.turnEnded(id: "s", clean: true)
        try await waitPastGrace()
        #expect(spy.fired == ["s"])
    }

    @Test
    func cancelDropsAPendingFire() async throws {
        // Closing the tab (cancel) drops a scheduled fire.
        let (debouncer, spy) = makeDebouncer()
        debouncer.arm(id: "s")
        debouncer.turnEnded(id: "s", clean: true)
        debouncer.cancel(id: "s")

        try await waitPastGrace()
        #expect(spy.fired.isEmpty)
    }
}
