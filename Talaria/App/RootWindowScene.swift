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
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(directory)
            .environment(recents)
            .task {
                await directory.reload()
                recents.record(profileId)
            }
    }
}
