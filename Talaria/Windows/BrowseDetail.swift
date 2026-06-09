import HermesKit
import SwiftUI

/// Maps a `BrowseDestination` to its concrete manage surface, fed by the shared
/// `ServerWindowHarness`. The desktop window's detail column and the iPhone
/// Browse sheet both render through this one switch so the two surfaces never
/// drift apart.
struct BrowseDetailView: View {
    let harness: ServerWindowHarness
    let destination: BrowseDestination
    /// Hermes profiles on the server, surfaced by the window — fed to the
    /// Configuration editor's compare dropdown.
    var hermesProfiles: [HermesProfileInfo] = []
    /// The window's active Hermes profile (`-p <name>`), highlighted in the
    /// Profiles management table.
    var activeHermesProfile: String = HermesProfiles.defaultProfileName
    /// Invoked after a Profiles mutation so the window refreshes its sidebar
    /// switcher and reconciles the active profile if it was renamed/deleted.
    var onProfilesChanged: () -> Void = {}

    var body: some View {
        switch destination {
        case .sessions:
            SessionsBrowser(store: harness.store, client: harness.dashboardClient)
        case .extensions:
            ExtensionsTabsView(harness: harness)
        case .cron:
            CronView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
        case .kanban:
            KanbanView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
        case .gateway:
            GatewayView(
                client: harness.dashboardClient,
                runner: harness.store.adminRunner,
                hermesVersion: harness.effectiveHermesVersion
            )
        case .hermesProfiles:
            ProfilesView(
                client: harness.dashboardClient,
                activeProfile: activeHermesProfile,
                hermesVersion: harness.effectiveHermesVersion,
                onProfilesChanged: onProfilesChanged
            )
        case .profiles:
            ConfigEnvironmentTabsView(harness: harness, hermesProfiles: hermesProfiles)
        case .personalities:
            SoulPersonalitiesMemoryTabsView(harness: harness)
        case .models:
            ModelsView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
        case .system:
            SystemTabsView(harness: harness)
        }
    }
}
