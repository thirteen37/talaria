import HermesKit
import SwiftUI

/// One platform row in the gateway table, derived from `gateway_platforms`.
/// Left `internal` (no access modifier) because it's the element type of
/// `GatewayHarness.platforms`, which is itself `internal` — a `private`/
/// `fileprivate` row type can't be the return type of an `internal` property
/// even within the same file.
struct GatewayPlatformRow: Identifiable, Equatable {
    let name: String
    let platform: GatewayPlatform

    var id: String { name }
}

@MainActor
@Observable
final class GatewayHarness {
    var status: DashboardStatus?
    var lastError: String?
    var isLoading: Bool = false
    /// True while a lifecycle command runs, so the action buttons disable to
    /// prevent overlapping start/stop/restart/install/uninstall calls.
    var busy: Bool = false

    private let client: DashboardClient
    private let runner: HermesAdminRunning?

    init(client: DashboardClient, runner: HermesAdminRunning?) {
        self.client = client
        self.runner = runner
    }

    /// Lifecycle writes go through the CLI admin runner — there's no dashboard
    /// HTTP control route. Nil on the iPad-local path, where status still shows
    /// but the action buttons stay disabled.
    var hasRunner: Bool { runner != nil }

    /// `gateway_running` from the dashboard. The badge and Start/Stop/Restart
    /// gating key off this rather than `gatewayState`, which is purely
    /// descriptive (`running` / `stopped` / `startup_failed` / `draining`).
    var isRunning: Bool { status?.gatewayRunning == true }

    var pid: Int? { status?.gatewayPid }
    var updatedAt: String? { status?.gatewayUpdatedAt }
    var exitReason: String? { status?.gatewayExitReason }

    /// Platforms sorted by name for a stable table order.
    var platforms: [GatewayPlatformRow] {
        (status?.gatewayPlatforms ?? [:])
            .map { GatewayPlatformRow(name: $0.key, platform: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await client.getStatus()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start() async { await perform { try await HermesGateway.start(runner: $0) } }
    func stop() async { await perform { try await HermesGateway.stop(runner: $0) } }
    func restart() async { await perform { try await HermesGateway.restart(runner: $0) } }
    func install() async { await perform { try await HermesGateway.install(runner: $0) } }
    func uninstall() async { await perform { try await HermesGateway.uninstall(runner: $0) } }

    /// Runs a lifecycle command, then refreshes status so the badge/platform
    /// rows reflect the new state. Errors surface in the banner. Same pattern
    /// the Cron/Profiles harnesses use for their writes.
    private func perform(_ command: (HermesAdminRunning) async throws -> Void) async {
        guard let runner else { return }
        busy = true
        defer { busy = false }
        do {
            try await command(runner)
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct GatewayView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

    @State private var harness: GatewayHarness?
    @State private var showUninstallConfirm = false

    init(client: DashboardClient?, runner: HermesAdminRunning?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.runner = runner
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Gateway")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (matching Cron/Profiles).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = GatewayHarness(client: client, runner: runner)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: GatewayHarness) -> some View {
        VStack(spacing: 0) {
            statusHeader(harness: harness)
            Divider()
            platformsTable(harness: harness)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { toolbar(harness: harness) }
        .alert("Uninstall gateway service?", isPresented: $showUninstallConfirm) {
            Button("Uninstall", role: .destructive) {
                Task { await harness.uninstall() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The gateway background service will be removed. Messaging platforms stop until it is reinstalled. This cannot be undone.")
        }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresDashboard,
                feature: "Gateway status via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
    }

    @ViewBuilder
    private func statusHeader(harness: GatewayHarness) -> some View {
        HStack(spacing: 12) {
            stateBadge(harness: harness)
            VStack(alignment: .leading, spacing: 2) {
                if let pid = harness.pid {
                    LabeledContent("PID") {
                        Text(String(pid)).font(.system(.body, design: .monospaced))
                    }
                }
                if let updatedAt = harness.updatedAt {
                    LabeledContent("Updated") {
                        Text(updatedAt).foregroundStyle(.secondary)
                    }
                }
                if let exitReason = harness.exitReason {
                    LabeledContent("Exit reason") {
                        Text(exitReason).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private func stateBadge(harness: GatewayHarness) -> some View {
        let descriptor = badgeDescriptor(harness: harness)
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(descriptor.color)
            Text(descriptor.label)
                .font(.headline)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(descriptor.color.opacity(0.15), in: Capsule())
    }

    private func badgeDescriptor(harness: GatewayHarness) -> (label: String, color: Color) {
        if harness.isRunning {
            return ("Running", .green)
        }
        // Not running: lean on `gatewayState` for the descriptive label. A null
        // state (never started / no runtime file) reads as "Not running".
        switch harness.status?.gatewayState {
        case "startup_failed": return ("Startup failed", .red)
        case "draining": return ("Draining", .orange)
        case "stopped": return ("Stopped", .orange)
        default: return ("Not running", .secondary)
        }
    }

    @ViewBuilder
    private func platformsTable(harness: GatewayHarness) -> some View {
        Table(harness.platforms) {
            TableColumn("Platform") { row in
                Text(row.name)
            }
            TableColumn("State") { row in
                Text(row.platform.state ?? "—")
                    .foregroundStyle(platformStateColor(row.platform.state))
            }
            TableColumn("Error") { row in
                Text(row.platform.errorMessage ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .overlay {
            if harness.platforms.isEmpty, !harness.isLoading {
                ContentUnavailableView(
                    "No platforms",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("No messaging platforms are reported for this gateway.")
                )
            }
        }
    }

    private func platformStateColor(_ state: String?) -> Color {
        switch state {
        case "connected": return .green
        case "connecting": return .orange
        case "error": return .red
        default: return .primary
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: GatewayHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Refresh the gateway status")

            Button { Task { await harness.start() } } label: {
                Label("Start", systemImage: "play")
            }
            .disabled(!harness.hasRunner || harness.busy || harness.isRunning)
            .help("Start the gateway service")

            Button { Task { await harness.stop() } } label: {
                Label("Stop", systemImage: "stop")
            }
            .disabled(!harness.hasRunner || harness.busy || !harness.isRunning)
            .help("Stop the gateway service")

            Button { Task { await harness.restart() } } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!harness.hasRunner || harness.busy || !harness.isRunning)
            .help("Restart the gateway service")

            Button { Task { await harness.install() } } label: {
                Label("Install", systemImage: "square.and.arrow.down")
            }
            .disabled(!harness.hasRunner || harness.busy)
            .help("Install the gateway as a background service")

            Button { showUninstallConfirm = true } label: {
                Label("Uninstall", systemImage: "trash")
            }
            .disabled(!harness.hasRunner || harness.busy)
            .help("Uninstall the gateway background service")
        }
    }
}
