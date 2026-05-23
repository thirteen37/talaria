import HermesKit
import SwiftUI

struct ServerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let directory: ProfileDirectory
    let recents: RecentServers

    var body: some Commands {
        CommandMenu("Servers") {
            Menu("New Server Window") {
                ForEach(directory.allProfiles) { profile in
                    Button(profile.name) {
                        openProfile(profile.id)
                    }
                }
                if directory.profiles.isEmpty {
                    Divider()
                    Text("No remote profiles configured")
                        .foregroundStyle(.secondary)
                }
            }

            Menu("Recent Servers") {
                let recentProfiles = recents.ids.compactMap(directory.profile(id:))
                if recentProfiles.isEmpty {
                    Text("No recently opened servers")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentProfiles) { profile in
                        Button(profile.name) {
                            openProfile(profile.id)
                        }
                    }
                    Divider()
                    Button("Clear") {
                        recents.clear()
                    }
                }
            }
        }
    }

    private func openProfile(_ id: UUID) {
        recents.record(id)
        openWindow(value: id)
    }
}
