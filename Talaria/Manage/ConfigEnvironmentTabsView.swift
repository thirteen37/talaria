import HermesKit
import SwiftUI

/// Collapses the two "how this Hermes server is configured" surfaces —
/// the config.yaml editor and the .env editor — behind a single
/// **Configuration** sidebar/Browse entry. A thin `TabView` wrapper that
/// forwards the inputs `BrowseDetailView` already has on hand to the two
/// existing views unchanged. Each child keeps its own `.navigationTitle`,
/// so the detail title tracks the active tab.
struct ConfigEnvironmentTabsView: View {
    let harness: ServerWindowHarness
    /// Hermes profiles on the server — fed to the Configuration editor's
    /// compare dropdown.
    var hermesProfiles: [HermesProfileInfo] = []
    /// Defaults to the Configuration (config.yaml) tab.
    @State private var selection: Tab = .configuration

    enum Tab { case configuration, environment }

    var body: some View {
        TabView(selection: $selection) {
            ConfigEditorContainer(windowHarness: harness, profiles: hermesProfiles)
                .tabItem { Label("Configuration", systemImage: "slider.horizontal.3") }
                .tag(Tab.configuration)

            EnvironmentView(
                client: harness.dashboardClient,
                hermesVersion: harness.profile.version,
                runner: harness.store.adminRunner,
                snapshotTransfer: harness.snapshotTransfer,
                profile: harness.profile
            )
            .tabItem { Label("Environment", systemImage: "key.fill") }
            .tag(Tab.environment)
        }
    }
}
