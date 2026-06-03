import SwiftUI

/// Collapses the three "operate / inspect the running Hermes" surfaces —
/// Doctor, Updates, and Logs — behind a single **System** sidebar/Browse entry.
/// A thin `TabbedDestinationView` wrapper that forwards the inputs
/// `BrowseDetailView` already has on hand to the three existing views unchanged.
/// Each child keeps its own `.navigationTitle`, so the detail title tracks the
/// active tab.
struct SystemTabsView: View {
    let harness: ServerWindowHarness

    var body: some View {
        TabbedDestinationView(tabs: [
            DestinationTab(id: "doctor", title: "Doctor", systemImage: "stethoscope") {
                DoctorView(
                    doctor: harness.doctor,
                    profile: harness.profile,
                    client: harness.dashboardClient,
                    hermesVersion: harness.effectiveHermesVersion
                )
            },
            DestinationTab(id: "updates", title: "Updates", systemImage: "arrow.down.circle") {
                UpdatesView(updates: harness.updates, hermesVersion: harness.effectiveHermesVersion)
            },
            DestinationTab(id: "logs", title: "Logs", systemImage: "doc.text") {
                LogsView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
            },
        ])
    }
}
