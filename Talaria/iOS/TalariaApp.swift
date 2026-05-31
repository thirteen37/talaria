import HermesKit
import SwiftUI

@main
struct TalariaApp: App {
    @State private var directory = ProfileDirectory()
    @State private var recents = RecentServers()
    @State private var sidebarLayout = SidebarLayout()

    var body: some Scene {
        WindowGroup(for: UUID.self) { $profileId in
            RootWindowScene(profileId: profileId, directory: directory, recents: recents, sidebarLayout: sidebarLayout) {
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
