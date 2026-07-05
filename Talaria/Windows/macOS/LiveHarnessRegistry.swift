import HermesKit
import SwiftUI

/// Process-wide directory that lets a popped-out chat window (`PoppedChatWindow`)
/// find the *live* `ServerWindowHarness` its source window already built, keyed by
/// profile id — modeled on `IncomingShareCoordinator.shared` /
/// `ChatNotifier.shared`.
///
/// This is the seam that lets a pop-out **share** the source window's existing
/// gateway WebSocket, `SessionManager`, and `SessionsStore` instead of building
/// its own (which would open a second socket and re-`session.resume`). A
/// `WindowGroup(for:)` value must be `Codable`, so it can't carry an object
/// reference — the live harness is handed across windows through this registry
/// instead.
///
/// References are **weak**: when a source window closes and its harness
/// deallocates, its slot is left dangling until the next `register`/`deregister`
/// touches the map. To make "closing the main window closes the pop-out" prompt
/// and *observable*, the source window explicitly `deregister`s on teardown,
/// which mutates the `@Observable` map and re-evaluates any observing pop-out.
@MainActor
@Observable
final class LiveHarnessRegistry {
    static let shared = LiveHarnessRegistry()
    private init() {}

    /// Weak box so a stored harness doesn't keep a closed window's whole object
    /// graph (store, dashboard, sockets) alive — the connection's lifetime stays
    /// owned by the source window, per the pop-out design.
    private struct WeakHarness {
        weak var harness: ServerWindowHarness?
    }

    /// Weak, profile-keyed live harnesses. Observed by `PoppedChatWindow` (reading
    /// `harness(forProfile:)` establishes the dependency), so a `register` /
    /// `deregister` mutation re-evaluates the pop-out.
    private var harnesses: [UUID: WeakHarness] = [:]

    /// Records `harness` as the live one for its profile, replacing any prior
    /// entry. A Hermes-profile switch rebuilds the harness under the *same*
    /// server profile id, so the newest (live) harness wins the slot.
    func register(_ harness: ServerWindowHarness) {
        harnesses[harness.profile.id] = WeakHarness(harness: harness)
    }

    /// Removes `harness` from the registry — but only if it's still the stored
    /// instance, so a late teardown of a switched-away harness can't evict the
    /// newer one that replaced it under the same profile id.
    func deregister(_ harness: ServerWindowHarness) {
        guard harnesses[harness.profile.id]?.harness === harness else { return }
        harnesses[harness.profile.id] = nil
    }

    /// The live harness for `profileId`, or nil if none is registered (or the
    /// registered one has since deallocated). Reading this from a view body
    /// subscribes it to registry changes.
    func harness(forProfile profileId: UUID) -> ServerWindowHarness? {
        harnesses[profileId]?.harness
    }
}
