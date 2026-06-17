import HermesKit
import SwiftUI

@main
struct TalariaApp: App {
    // Installs `ChatNotifier.shared` as the notification-center delegate at
    // launch so a tap that cold-launches the app is captured.
    @UIApplicationDelegateAdaptor(TalariaLaunchDelegate.self) private var launchDelegate
    @State private var directory = ProfileDirectory()
    @State private var recents = RecentServers()
    @State private var sidebarLayout = SidebarLayout()
    // The single shared notification preferences instance (owned by
    // `ChatNotifier`), injected into the windows (and the iOS settings sheet,
    // which reads it from the environment).
    @State private var notificationSettings = ChatNotifier.shared.settings
    // Persists each window's navigation + open-session state so a cold relaunch
    // (iOS terminated the suspended app) restores where the user left off.
    @State private var windowRestoration = WindowRestorationStore()

    var body: some Scene {
        WindowGroup(for: UUID.self) { $profileId in
            RootWindowScene(profileId: profileId, directory: directory, recents: recents, sidebarLayout: sidebarLayout, notificationSettings: notificationSettings, windowRestoration: windowRestoration) {
                ServerWindowRoot(profileId: profileId)
            }
        } defaultValue: {
            // Last-opened profile wins on launch (see the macOS entry for the
            // synchronous-read rationale).
            recents.ids.first ?? ProfileDirectory.localProfileID
        }
        // iPad (hardware keyboard) gets the section/new-session/profile menu
        // commands; they read the focused `DesktopServerWindow`'s model. iPhone
        // runs `PhoneServerWindow`, which publishes none, so its items stay the
        // disabled fallback — harmless (iPhone has no menu bar). No Sparkle /
        // Settings scene on iOS: editing is surfaced inside the window (gear
        // toolbar / compact Settings sheet).
        .commands {
            WindowCommands(recents: recents)
        }
    }
}
