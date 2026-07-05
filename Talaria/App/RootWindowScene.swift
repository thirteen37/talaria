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
    /// Cold-relaunch navigation restore store. Injected on iOS (where the app can
    /// be killed-and-restored); nil on macOS, where the windows read it as the
    /// optional `nil` form and the save/restore wiring stays inert.
    var windowRestoration: WindowRestorationStore? = nil
    /// Explicit window-frame autosave name. Nil → key the frame by launch
    /// `profileId` (the main window). Popped-out chat windows pass a session-keyed
    /// name so they don't share the main window's (profile-keyed) frame slot.
    var frameAutosaveName: String? = nil
    /// Whether to run the launch task (reload the profile directory, record the
    /// profile as recently-opened). True for a primary window opened *for* a
    /// profile; false for a derived window (a chat pop-out) that only mirrors an
    /// already-open session — there, `directory.reload()` is a redundant disk read
    /// and `recents.record` would wrongly reorder the recent-servers list.
    var runsLaunchTask: Bool = true
    @ViewBuilder var content: () -> Content

    @Environment(\.openWindow) private var openWindow
    private var notifier: ChatNotifier { .shared }

    var body: some View {
        framedContent()
            .environment(directory)
            .environment(recents)
            .environment(sidebarLayout)
            .environment(notificationSettings)
            .environment(windowRestoration)
            .task {
                guard runsLaunchTask else { return }
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

    /// The window content with its frame autosave applied: an explicit
    /// session-keyed name when given (pop-out windows), else the launch-profile
    /// default. `frameAutosaveName` is constant per scene, so the conditional
    /// never re-keys a live window.
    @ViewBuilder
    private func framedContent() -> some View {
        if let frameAutosaveName {
            content().rememberWindowFrame(named: frameAutosaveName)
        } else {
            content().rememberWindowFrame(for: profileId)
        }
    }

    private func focusWindow(for route: NotificationRoute?) {
        guard let route else { return }
        openWindow(value: route.profileId)
    }
}
