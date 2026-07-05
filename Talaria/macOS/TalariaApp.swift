import HermesKit
import SwiftUI

@main
struct TalariaApp: App {
    // Installs `ChatNotifier.shared` as the notification-center delegate at
    // launch so a tap that cold-launches the app is captured.
    @NSApplicationDelegateAdaptor(TalariaLaunchDelegate.self) private var launchDelegate
    @State private var directory = ProfileDirectory()
    @State private var recents = RecentServers()
    @State private var sidebarLayout = SidebarLayout()
    // The single shared notification preferences instance (owned by
    // `ChatNotifier`), injected into the windows and the Settings scene.
    @State private var notificationSettings = ChatNotifier.shared.settings
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        WindowGroup(for: UUID.self) { $profileId in
            RootWindowScene(profileId: profileId, directory: directory, recents: recents, sidebarLayout: sidebarLayout, notificationSettings: notificationSettings) {
                DesktopServerWindow(profileId: profileId)
            }
        } defaultValue: {
            // Last-opened profile wins on launch. `RecentServers.init` reads
            // UserDefaults synchronously, so the first window opened on app
            // launch sees the user's prior session's choice instead of
            // always landing on the bundled local profile.
            recents.ids.first ?? ProfileDirectory.localProfileID
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.updater)
            }
            ServerCommands(directory: directory, recents: recents)
            WindowCommands(recents: recents)
        }

        // Popped-out single-chat windows. Keyed by `{profileId, sessionId}` so
        // popping the same session twice focuses the existing window instead of
        // spawning a duplicate. `RootWindowScene` supplies the shared environment
        // and a session-keyed frame slot (so pop-outs don't fight the main
        // window's profile-keyed frame). The window resolves and shares the source
        // window's live harness via `LiveHarnessRegistry` — no new connection.
        WindowGroup(for: PoppedChatRoute.self) { $route in
            if let route {
                RootWindowScene(
                    profileId: route.profileId,
                    directory: directory,
                    recents: recents,
                    sidebarLayout: sidebarLayout,
                    notificationSettings: notificationSettings,
                    frameAutosaveName: "PoppedChatWindow-\(route.sessionId)",
                    // A pop-out only mirrors an already-open session (resolved from
                    // the live harness), so skip the primary-window launch work:
                    // no redundant directory reload, and don't reorder recents.
                    runsLaunchTask: false
                ) {
                    PoppedChatWindow(route: route)
                }
            }
        }

        Settings {
            SettingsScene()
                .environment(directory)
                .environment(sidebarLayout)
                .environment(notificationSettings)
        }
    }
}
