import HermesKit
import SwiftUI

/// Shared `WindowGroup` content wrapper: injects the app-wide environment
/// objects and runs the per-window launch task (reload directory, record the
/// opened profile as recent). The platform `@main` apps wrap their respective
/// window view (`DesktopServerWindow` on macOS, `ServerWindowRoot` on iOS) in
/// this so the launch plumbing lives in one place.
struct RootWindowScene<Content: View>: View {
    let profileId: UUID
    let directory: ProfileDirectory
    let recents: RecentServers
    let sidebarLayout: SidebarLayout
    let notificationSettings: NotificationSettings
    @ViewBuilder var content: () -> Content

    @Environment(\.openWindow) private var openWindow
    private var notifier: ChatNotifier { .shared }

    var body: some View {
        content()
            .environment(directory)
            .environment(recents)
            .environment(sidebarLayout)
            .environment(notificationSettings)
            .task {
                await directory.reload()
                recents.record(profileId)
            }
            // Deep-link reactor: when a tapped notification publishes a route,
            // bring its profile's window to the front. SwiftUI matches the
            // existing `WindowGroup(for: UUID.self)` window on the value, so this
            // focuses rather than spawns. The matching window's
            // `chatNotificationRouting` then selects the session and clears the
            // route. Idempotent across windows — a repeat focus is harmless.
            //
            // On appear too, not only on change: on a cold launch the tap sets
            // `pendingRoute` before any scene is mounted, so `.onChange` (which
            // never fires for a pre-existing value) would miss it and the target
            // window would never be opened.
            .onAppear { focusWindow(for: notifier.pendingRoute) }
            .onChange(of: notifier.pendingRoute) { _, route in focusWindow(for: route) }
    }

    private func focusWindow(for route: NotificationRoute?) {
        guard let route else { return }
        openWindow(value: route.profileId)
    }
}
