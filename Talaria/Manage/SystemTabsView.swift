import SwiftUI

/// Collapses the three "operate / inspect the running Hermes" surfaces —
/// Doctor, Updates, and Logs — behind a single **System** sidebar/Browse entry.
/// A thin `TabView` wrapper that forwards the inputs `BrowseDetailView` already
/// has on hand to the three existing views unchanged. Each child keeps its own
/// `.navigationTitle`, so the detail title tracks the active tab.
struct SystemTabsView: View {
    let harness: ServerWindowHarness
    /// Defaults to the Doctor tab — the most actionable of the three surfaces.
    @State private var selection: Tab = .doctor

    enum Tab { case doctor, updates, logs }

    var body: some View {
        TabView(selection: $selection) {
            DoctorView(
                doctor: harness.doctor,
                profile: harness.profile,
                client: harness.dashboardClient,
                hermesVersion: harness.effectiveHermesVersion
            )
            .tabItem { Label("Doctor", systemImage: "stethoscope") }
            .tag(Tab.doctor)

            UpdatesView(updates: harness.updates, hermesVersion: harness.effectiveHermesVersion)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)

            LogsView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
                .tabItem { Label("Logs", systemImage: "doc.text") }
                .tag(Tab.logs)
        }
    }
}
