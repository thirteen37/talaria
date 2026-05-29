import HermesKit
import SwiftUI

@main
struct TalariaApp: App {
    @State private var directory = ProfileDirectory()
    @State private var recents = RecentServers()

    var body: some Scene {
        WindowGroup(for: UUID.self) { $profileId in
            RootWindowScene(profileId: profileId, directory: directory, recents: recents) {
                ServerWindowRoot(profileId: profileId)
            }
        } defaultValue: {
            // Last-opened profile wins on launch (see the macOS entry for the
            // synchronous-read rationale).
            recents.ids.first ?? ProfileDirectory.localProfileID
        }
        // No Sparkle / menu commands / Settings scene on iOS: editing is
        // surfaced inside the window (gear toolbar / compact Settings sheet).
    }
}
