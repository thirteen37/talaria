import HermesKit
import SwiftUI

/// Collapses the two profile surfaces — managing the server's Hermes profiles
/// (list, clone/rename/delete, distributions) and **syncing** the default
/// profile's skills/config/credentials into the named ones — behind the single
/// **Profiles** sidebar/Browse entry. A thin `TabbedDestinationView` wrapper
/// that forwards the inputs `BrowseDetailView` already has on hand to the two
/// views. Each child keeps its own `.navigationTitle`, so the detail title
/// tracks the active tab.
struct ProfilesTabsView: View {
    let harness: ServerWindowHarness
    /// The window's active Hermes profile (`-p <name>`), highlighted in the
    /// management table.
    var activeProfile: String = HermesProfiles.defaultProfileName
    /// Invoked after a Profiles mutation so the window refreshes its sidebar
    /// switcher and reconciles the active profile if it was renamed/deleted.
    var onProfilesChanged: () -> Void = {}

    @State private var tab = "profiles"
    /// Set when the Profiles tab deep-links to a specific profile's Sync; the
    /// Sync view consumes it (selects that profile, then clears it).
    @State private var syncTarget: String?

    var body: some View {
        TabbedDestinationView(selection: $tab, tabs: [
            DestinationTab(id: "profiles", title: "Profiles", systemImage: "person.2.crop.square.stack") {
                ProfilesView(
                    client: harness.dashboardClient,
                    runner: harness.store.adminRunner,
                    profile: harness.profile,
                    snapshotTransfer: harness.snapshotTransfer,
                    hostShell: harness.hostShell,
                    activeProfile: activeProfile,
                    hermesVersion: harness.effectiveHermesVersion,
                    onProfilesChanged: onProfilesChanged,
                    onShowSync: { profile in
                        syncTarget = profile
                        tab = "sync"
                    }
                )
            },
            DestinationTab(id: "sync", title: "Sync", systemImage: "arrow.triangle.2.circlepath") {
                ProfileSyncView(
                    baseRunner: harness.baseAdminRunner,
                    windowClient: { harness.dashboardClient },
                    profile: harness.profile,
                    snapshotTransfer: harness.snapshotTransfer,
                    hermesVersion: harness.effectiveHermesVersion,
                    activeProfile: harness.hermesProfileName,
                    syncTarget: $syncTarget
                )
            },
        ])
    }
}
