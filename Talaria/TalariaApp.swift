import HermesKit
import SwiftUI

@main
struct TalariaApp: App {
    @State private var directory = ProfileDirectory()
    @State private var recents = RecentServers()

    var body: some Scene {
        WindowGroup(for: UUID.self) { $profileId in
            ServerWindow(profileId: profileId ?? ProfileDirectory.localProfileID)
                .environment(directory)
                .task {
                    await directory.reload()
                    recents.record(profileId ?? ProfileDirectory.localProfileID)
                }
        } defaultValue: {
            ProfileDirectory.localProfileID
        }
        .commands {
            ServerCommands(directory: directory, recents: recents)
        }

        Settings {
            SettingsScene()
                .environment(directory)
        }
    }
}
