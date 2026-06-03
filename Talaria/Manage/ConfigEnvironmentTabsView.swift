import HermesKit
import SwiftUI

/// Collapses the two "how this Hermes server is configured" surfaces —
/// the config.yaml editor and the .env editor — behind a single
/// **Configuration** sidebar/Browse entry. A thin `TabbedDestinationView`
/// wrapper that forwards the inputs `BrowseDetailView` already has on hand to
/// the two existing views unchanged. Each child keeps its own
/// `.navigationTitle`, so the detail title tracks the active tab.
struct ConfigEnvironmentTabsView: View {
    let harness: ServerWindowHarness
    /// Hermes profiles on the server — fed to the Configuration editor's
    /// compare dropdown.
    var hermesProfiles: [HermesProfileInfo] = []

    var body: some View {
        TabbedDestinationView(tabs: [
            DestinationTab(id: "configuration", title: "Configuration", systemImage: "slider.horizontal.3") {
                ConfigEditorContainer(windowHarness: harness, profiles: hermesProfiles)
            },
            DestinationTab(id: "environment", title: "Environment", systemImage: "key.fill") {
                EnvironmentView(
                    client: harness.dashboardClient,
                    hermesVersion: harness.effectiveHermesVersion,
                    runner: harness.store.adminRunner,
                    snapshotTransfer: harness.snapshotTransfer,
                    profile: harness.profile
                )
            },
        ])
    }
}
