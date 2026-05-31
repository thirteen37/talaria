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
        case .plugins:
            PluginsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .tools:
            ToolsView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
        case .cron:
            CronView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .gateway:
            GatewayView(
                client: harness.dashboardClient,
                runner: harness.store.adminRunner,
                hermesVersion: harness.profile.version
            )
        case .hermesProfiles:
            ProfilesView(
                client: harness.dashboardClient,
                runner: harness.store.adminRunner,
                activeProfile: activeHermesProfile,
                hermesVersion: harness.profile.version,
                onProfilesChanged: onProfilesChanged
            )
        case .profiles:
            ConfigEditorContainer(windowHarness: harness, profiles: hermesProfiles)
        case .soul:
            SoulEditorContainer(windowHarness: harness)
        case .models:
            ModelsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .environment:
            EnvironmentView(
                client: harness.dashboardClient,
                hermesVersion: harness.profile.version,
                runner: harness.store.adminRunner,
                snapshotTransfer: harness.snapshotTransfer,
                profile: harness.profile
            )
        case .logs:
            LogsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
        case .doctor:
            DoctorView(
                doctor: harness.doctor,
                profile: harness.profile,
                client: harness.dashboardClient,
                hermesVersion: harness.profile.version
            )
        case .updates:
            UpdatesView(updates: harness.updates, hermesVersion: harness.profile.version)
        case .notifications:
            NotificationsView(center: harness.notifications, onOpenDestination: onOpenDestination)
        }
    }
}
