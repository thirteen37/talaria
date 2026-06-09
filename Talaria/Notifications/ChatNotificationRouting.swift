import HermesKit
import SwiftUI

extension View {
    /// Wires a window's chat notifications. Two jobs:
    /// - Reports the window's foreground state into the store (via the platform
    ///   `trackWindowForeground` seam) so a chat already on screen is never
    ///   notified.
    /// - Consumes a tapped-notification route addressed to this window's profile:
    ///   focuses the session, then clears the shared route.
    ///
    /// Shared across the desktop and iPhone window roots; the foreground source
    /// (`controlActiveState` on macOS, `scenePhase` on iOS) lives behind the seam.
    /// Takes the whole `harness` (not just `store`/`profileId`) so it can drive
    /// the iOS/iPad background→foreground connection recovery.
    func chatNotificationRouting(harness: ServerWindowHarness) -> some View {
        modifier(ChatNotificationRouting(harness: harness))
    }
}

private struct ChatNotificationRouting: ViewModifier {
    let harness: ServerWindowHarness
    private var store: SessionsStore { harness.store }
    private var profileId: UUID { harness.profile.id }
    private var notifier: ChatNotifier { .shared }

    // `Self.Content` (not bare `Content`) because this file imports HermesKit,
    // which also exports a `Content` type — the bare name would resolve to that
    // and break the `ViewModifier` conformance.
    func body(content: Self.Content) -> some View {
        content
            .trackWindowForeground { store.isWindowForeground = $0 }
            // On a real background→foreground round-trip, probe the dashboard and
            // reconnect only if the suspended SSH connection died. No-op on macOS
            // (the seam is a no-op there); fires on iPhone + iPad.
            .onResumeFromBackground { harness.recoverConnectionIfNeeded() }
            // Consume on appear AND on change: a window opened *in response to* a
            // tap (warm "open the target window", or a cold launch) mounts with
            // `pendingRoute` already set, and `.onChange` never fires for a
            // pre-existing value — so the session would never be selected and the
            // stale route would block a second tap. `.onAppear` catches that case;
            // `.onChange` catches a tap that arrives while the window is open.
            .onAppear { consume(notifier.pendingRoute) }
            .onChange(of: notifier.pendingRoute) { _, route in consume(route) }
    }

    /// Selects the routed session and clears the route, but only for a route
    /// addressed to this window's profile.
    private func consume(_ route: NotificationRoute?) {
        guard let route, route.profileId == profileId else { return }
        store.focusSession(route: route)
        notifier.pendingRoute = nil
    }
}
