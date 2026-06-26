import SwiftUI

/// Collapses the "operate / inspect the running Hermes" surfaces —
/// Doctor, Updates, Logs, App Logs, and Usage — behind a single **System**
/// sidebar/Browse entry. A thin `TabbedDestinationView` wrapper that forwards
/// the inputs `BrowseDetailView` already has on hand to the existing views
/// unchanged. Each child keeps its own `.navigationTitle`, so the detail title
/// tracks the active tab.
///
/// `Logs` is the Hermes/dashboard log; `App Logs` is this app's own on-device
/// `OSLog` console (the former iPhone toolbar ladybug entry), embedded here with
/// no modal dismiss.
struct SystemTabsView: View {
    let harness: ServerWindowHarness

    var body: some View {
        TabbedDestinationView(tabs: [
            DestinationTab(
                id: "updates",
                title: "Updates",
                systemImage: "arrow.down.circle",
                badge: harness.updates?.status?.available == true ? Text("1") : nil
            ) {
                UpdatesView(updates: harness.updates, hermesVersion: harness.effectiveHermesVersion)
            },
            DestinationTab(id: "doctor", title: "Doctor", systemImage: "stethoscope") {
                DoctorView(
                    doctor: harness.doctor,
                    profile: harness.profile,
                    client: harness.dashboardClient,
                    hermesVersion: harness.effectiveHermesVersion
                )
            },
            DestinationTab(id: "logs", title: "Logs", systemImage: "doc.text") {
                LogsView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
            },
            DestinationTab(id: "appLogs", title: "App Logs", systemImage: "ladybug") {
                LogConsoleView()
            },
            DestinationTab(id: "usage", title: "Usage", systemImage: "chart.bar.xaxis") {
                UsageView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
            },
        ])
    }
}
