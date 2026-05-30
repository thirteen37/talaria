import HermesKit
import SwiftUI

/// Maps a `BrowseDestination` to its concrete manage surface, fed by the shared
/// `ServerWindowHarness`. The desktop window's detail column and the iPhone
/// Browse sheet both render through this one switch so the two surfaces never
/// drift apart.
struct BrowseDetailView: View {
    let harness: ServerWindowHarness
    let destination: BrowseDestination
    /// Lets `NotificationsView` deep-link into another destination (e.g. "Open
    /// Doctor"). Desktop points this at its `browse` selection; the iPhone sheet
    /// pushes onto its navigation path.
    var onOpenDestination: (BrowseDestination) -> Void = { _ in }

    var body: some View {
        switch destination {
        case .sessions:
            SessionsBrowser(store: harness.store, client: harness.dashboardClient)
        case .skills:
            SkillsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .tools:
            ToolsView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
        case .cron:
            CronView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .profiles:
            ProfilesView(runner: harness.store.adminRunner, profile: harness.profile, transfer: harness.snapshotTransfer)
        case .logs:
            LogsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .doctor:
            DoctorView(
                runner: harness.store.adminRunner,
                profile: harness.profile,
                client: harness.dashboardClient,
                hermesVersion: harness.profile.version
            )
        case .updates:
            UpdatesView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .notifications:
            NotificationsView(center: harness.notifications, onOpenDestination: onOpenDestination)
        }
    }
}
