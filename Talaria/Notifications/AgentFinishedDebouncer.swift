import Foundation
import HermesKit

/// Coalesces the "agent finished responding" notification across the chained
/// turns Hermes runs on one session.
///
/// Hermes wraps a whole agentic loop in one `run_conversation` and emits a
/// single `message.complete` at its end — but it then chains *additional*
/// `message.start … message.complete` cycles on the same session (background-
/// process completion reactions, `/goal` Ralph-loop continuations, autonomous
/// poller turns). Notifying on the first complete therefore fires "agent
/// finished" while a continuation's response is still streaming in. There is no
/// single authoritative "fully idle" event, so this coalesces with a short
/// debounce: it fires once, a grace period after the *last* clean turn-end with
/// no new turn-start in between.
///
/// Eligibility is **armed** by a user-initiated send (``arm(id:)``); a purely
/// autonomous turn the user never triggered never arms, so it never notifies. A
/// background-process / goal continuation inherits eligibility because the
/// debounce window is still open when it ends.
///
/// `@MainActor`-isolated (it's driven from ``SessionsStore``) and split out from
/// the store so the coalescing logic is unit-testable with an injected grace and
/// a spy `onFire`, the way ``NotificationPolicy`` is split from ``ChatNotifier``.
@MainActor
final class AgentFinishedDebouncer {
    /// Per-session pending fire. Cancelled (and replaced) whenever a new turn
    /// starts or a fresh clean end reschedules it.
    private var pending: [SessionId: Task<Void, Never>] = [:]
    /// Sessions a user send has made eligible to notify. A session leaves the
    /// set when it fires, when an unclean end disarms it, or when it's cancelled.
    private var armed: Set<SessionId> = []
    private let grace: Duration
    /// Invoked on the main actor when a coalesced turn settles. The store wires
    /// this to the fire-time policy gate + `postAgentFinished`.
    private let onFire: @MainActor (SessionId) -> Void

    init(grace: Duration = .milliseconds(1250), onFire: @escaping @MainActor (SessionId) -> Void) {
        self.grace = grace
        self.onFire = onFire
    }

    /// A user-initiated send makes this session eligible to notify when it
    /// settles. Idempotent.
    func arm(id: SessionId) {
        armed.insert(id)
    }

    /// A turn (or chained continuation) started — a continuation is running, so
    /// hold any pending notification until things settle again.
    func turnStarted(id: SessionId) {
        pending[id]?.cancel()
        pending[id] = nil
    }

    /// A turn ended. `clean == false` (interrupted/error) disarms and cancels any
    /// pending fire — matching "no notify on cancel/error". A clean end on an
    /// armed session (re)schedules the debounced fire `grace` later.
    func turnEnded(id: SessionId, clean: Bool) {
        guard clean else {
            cancel(id: id)
            return
        }
        guard armed.contains(id) else { return }
        pending[id]?.cancel()
        pending[id] = Task { [weak self, grace] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            // Still the active task (a new start/end would have cancelled it),
            // so clearing this slot and disarming is correct.
            self.pending[id] = nil
            self.armed.remove(id)
            self.onFire(id)
        }
    }

    /// Drops a session's pending fire and arm state (an unclean end, or a closed
    /// tab). Safe to call for an unknown session.
    func cancel(id: SessionId) {
        pending[id]?.cancel()
        pending[id] = nil
        armed.remove(id)
    }
}
