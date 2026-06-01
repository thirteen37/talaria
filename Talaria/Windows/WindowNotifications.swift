import HermesKit
import SwiftUI

/// Aggregates cross-cutting per-window issues that warrant attention.
/// Owned by ``ServerWindowHarness``; polls in the background until
/// ``stop()`` is called from `tearDown()`. The bell view in the sidebar
/// observes ``issues`` and lights up when any are present.
@MainActor
@Observable
final class WindowNotificationCenter {
    struct Issue: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case doctorFailure
        }
        let id: Kind
        let title: String
        let detail: String?
        /// Sidebar destination the row's action button navigates to.
        let destination: BrowseDestination
    }

    private(set) var issues: [Issue] = []

    private let adminRunner: HermesAdminRunning?
    private var doctorTask: Task<Void, Never>?

    /// Cadence for admin polls. 30 minutes balances freshness against
    /// shell-out cost on remote profiles.
    private static let adminPollInterval: Duration = .seconds(30 * 60)

    init(adminRunner: HermesAdminRunning?) {
        self.adminRunner = adminRunner
    }

    func start() {
        startDoctorTask()
    }

    func stop() {
        doctorTask?.cancel(); doctorTask = nil
    }

    /// Re-run the admin polls immediately (e.g. when the user opens the
    /// notifications page and wants a fresh read). Existing polling tasks
    /// keep running on their cadence.
    func refreshAdminChecks() {
        Task { await pollDoctor() }
    }

    private func startDoctorTask() {
        guard adminRunner != nil else { return }
        doctorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDoctor()
                try? await Task.sleep(for: Self.adminPollInterval)
            }
        }
    }

    private func pollDoctor() async {
        guard let runner = adminRunner else { return }
        do {
            let report = try await HermesDoctor.run(runner: runner)
            if report.exitCode != 0 {
                let firstSection = report.sections.first.map(\.title)
                upsert(Issue(
                    id: .doctorFailure,
                    title: "Doctor reports issues",
                    detail: firstSection.map { "\($0) (exit \(report.exitCode))" }
                        ?? "Exit \(report.exitCode)",
                    destination: .system
                ))
            } else {
                remove(.doctorFailure)
            }
        } catch {
            // Preserve the last known doctor verdict across transient
            // network or SSH failures.
        }
    }

    private func upsert(_ issue: Issue) {
        if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
            if issues[idx] != issue {
                issues[idx] = issue
            }
        } else {
            issues.append(issue)
        }
    }

    private func remove(_ kind: Issue.Kind) {
        issues.removeAll { $0.id == kind }
    }
}

/// Detail page that lists each active issue with a deep-link button to the
/// relevant sidebar destination.
struct NotificationsView: View {
    let center: WindowNotificationCenter
    let onOpenDestination: (BrowseDestination) -> Void

    var body: some View {
        Group {
            if center.issues.isEmpty {
                ContentUnavailableView(
                    "No notifications",
                    systemImage: "bell.slash",
                    description: Text("Cross-cutting issues will appear here.")
                )
            } else {
                List {
                    ForEach(center.issues) { issue in
                        row(for: issue)
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .task {
            // Out-of-band poll so the page reflects current state instead
            // of waiting up to 30 min for the next scheduled check.
            center.refreshAdminChecks()
        }
    }

    @ViewBuilder
    private func row(for issue: WindowNotificationCenter.Issue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: issue.id))
                .foregroundStyle(color(for: issue.id))
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.headline)
                if let detail = issue.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButton(for: issue)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButton(for issue: WindowNotificationCenter.Issue) -> some View {
        switch issue.id {
        case .doctorFailure:
            Button("Open Doctor") { onOpenDestination(.system) }
        }
    }

    private func icon(for kind: WindowNotificationCenter.Issue.Kind) -> String {
        switch kind {
        case .doctorFailure: return "stethoscope"
        }
    }

    private func color(for kind: WindowNotificationCenter.Issue.Kind) -> Color {
        switch kind {
        case .doctorFailure: return .orange
        }
    }
}
