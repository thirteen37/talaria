import HermesKit
import SwiftUI

@main
struct TalariaApp: App {
    @State private var directory = ProfileDirectory()
    @State private var recents = RecentServers()
    @State private var sidebarLayout = SidebarLayout()
    @StateObject private var updater = UpdateController()

    var body: some Scene {
        WindowGroup(for: UUID.self) { $profileId in
            RootWindowScene(profileId: profileId, directory: directory, recents: recents, sidebarLayout: sidebarLayout) {
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater.updater)
            }
            ServerCommands(directory: directory, recents: recents)
        }

        Settings {
            SettingsScene()
                .environment(directory)
                .environment(sidebarLayout)
        }
    }
}
