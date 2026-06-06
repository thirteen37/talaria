import HermesKit
import SwiftUI

/// One platform row in the gateway status table, derived from `gateway_platforms`.
/// Left `internal` (no access modifier) because it's the element type of
/// `GatewayHarness.statusOnlyRows`, which is itself `internal` — a `private`/
/// `fileprivate` row type can't be the return type of an `internal` property
/// even within the same file.
struct GatewayPlatformRow: Identifiable, Equatable {
    let name: String
    let platform: GatewayPlatform

    var id: String { name }
}

/// One element of the unified primary list: either an editable messaging
/// platform (it has at least one messaging env var) or a status-only platform
/// the gateway reports but that has no editable variable (e.g. config.yaml-only
/// Signal/WhatsApp/Email).
enum GatewayListItem: Identifiable {
    case platform(MessagingPlatformGroup)
    case statusOnly(GatewayPlatformRow)

    var id: String {
        switch self {
        case let .platform(group): return group.id
        case let .statusOnly(row): return row.id
        }
    }
}

@MainActor
@Observable
final class GatewayHarness {
    var status: DashboardStatus?
    /// Per-platform messaging cards, rebuilt on every refresh from the messaging
    /// env vars fused with the gateway status.
    var groups: [MessagingPlatformGroup] = []
    var lastError: String?
    /// Top-of-window banner hub (window-scoped); optional so a missing host
    /// degrades to no-op. Hard errors route here keyed by the surface id; a
    /// successful credential save posts a transient confirmation.
    var banners: BannerCenter?
    var isLoading: Bool = false
    /// The selected platform's `id` (drives the side panel).
    var selectionID: String?
    /// Env-var names with an in-flight save/delete, so their field controls
    /// disable while the request is outstanding. (Reveal has its own per-field
    /// spinner inside ``RevealableSecretField``.)
    var busy: Set<String> = []
    /// True while a gateway restart (from the side panel) runs.
    var restartBusy: Bool = false
    /// True while a lifecycle command runs, so the action buttons disable to
    /// prevent overlapping start/stop/restart/install/uninstall calls. Distinct
    /// from the env `busy` set above.
    var lifecycleBusy: Bool = false
    /// Bumped on every refresh so expanded fields re-mask any revealed secret —
    /// a revealed value must not stay in cleartext across a reload.
    private(set) var refreshToken: Int = 0

    private let client: DashboardClient
    /// Lifecycle writes (start/stop/restart/install/uninstall) go through the CLI
    /// admin runner — there's no dashboard HTTP control route. Nil on the
    /// iPad-local path, where status still shows but the action buttons stay
    /// disabled.
    private let runner: HermesAdminRunning?

    init(client: DashboardClient, runner: HermesAdminRunning?) {
        self.client = client
        self.runner = runner
    }

    var hasRunner: Bool { runner != nil }

    /// `gateway_running` from the dashboard. The badge and Start/Stop/Restart
    /// gating key off this rather than `gatewayState`, which is purely
    /// descriptive (`running` / `stopped` / `startup_failed` / `draining`).
    var isRunning: Bool { status?.gatewayRunning == true }

    /// Alias kept for the side-panel restart gating, which reads as
    /// "is the gateway running?" at the call site.
    var isGatewayRunning: Bool { isRunning }

    var pid: Int? { status?.gatewayPid }
    var updatedAt: String? { status?.gatewayUpdatedAt }
    var exitReason: String? { status?.gatewayExitReason }

    /// Gateway-reported platforms with no editable messaging card — every
    /// `gateway_platforms` key not covered by a messaging group. Catalog `id ==
    /// statusKey` for every entry, so a group's `id` is its `gateway_platforms`
    /// key; anything left over is config.yaml-only (Signal/WhatsApp/Email).
    var statusOnlyRows: [GatewayPlatformRow] {
        let covered = Set(groups.map(\.id))
        return (status?.gatewayPlatforms ?? [:])
            .filter { !covered.contains($0.key) }
            .map { GatewayPlatformRow(name: $0.key, platform: $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Unified primary list: editable platform cards first, then status-only
    /// rows.
    var listItems: [GatewayListItem] {
        groups.map(GatewayListItem.platform) + statusOnlyRows.map(GatewayListItem.statusOnly)
    }

    /// The selected list element, or nil when nothing is selected (the side
    /// panel hides).
    var selectedItem: GatewayListItem? {
        guard let id = selectionID else { return nil }
        return listItems.first { $0.id == id }
    }

    /// Loads env vars + gateway status concurrently (the `MessagingHarness`
    /// pattern). The env list is required; a `/api/status` failure is tolerated
    /// (cards still render, connection pills read "unknown").
    func refresh() async {
        isLoading = true
        refreshToken &+= 1
        defer { isLoading = false }

        async let envTask = client.listEnvVars()
        async let statusTask = client.getStatus()

        // Status is best-effort — fetch it first so a failure only clears the
        // pills, never the cards.
        status = try? await statusTask

        do {
            let envVars = try await envTask
            groups = groupMessagingPlatforms(
                envVars: envVars,
                gatewayPlatforms: status?.gatewayPlatforms ?? [:]
            )
            lastError = nil
            banners?.dismiss(key: "gateway")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("gateway", error.localizedDescription)
        }
    }

    // MARK: - Messaging env writes

    func save(key: String, value: String) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await client.setEnvVar(key: key, value: value)
            await refresh()
            // Only confirm if the post-write reload also succeeded — otherwise
            // refresh() has posted its own error and an unconditional success
            // here would dismiss it, hiding a failed reload over stale data.
            if lastError == nil {
                banners?.surfaceSuccess("gateway", "Gateway setting saved")
            }
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("gateway", error.localizedDescription)
        }
    }

    func delete(key: String) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await client.deleteEnvVar(key: key)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("gateway", error.localizedDescription)
        }
    }

    /// Fetches one var's unredacted value on demand. Returns nil (and sets
    /// `lastError`) on failure. The plaintext lives only in the requesting
    /// field's view state, so it can't linger past that field — no harness-side
    /// reveal cache or selection-scoped clearing is needed.
    func revealValue(key: String) async -> String? {
        do {
            let value = try await client.revealEnvVar(key: key)
            lastError = nil
            return value
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("gateway", error.localizedDescription)
            return nil
        }
    }

    /// Restarts the gateway so a just-saved platform credential takes effect,
    /// then refreshes status. No-ops without a runner (no dashboard route). This
    /// is the side-panel contextual restart; the toolbar Restart uses
    /// `restart()` below.
    func restartGateway() async {
        guard let runner else { return }
        restartBusy = true
        defer { restartBusy = false }
        do {
            try await HermesGateway.restart(runner: runner)
            lastError = nil
            banners?.dismiss(key: "gateway")
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("gateway", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle

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
        lifecycleBusy = true
        defer { lifecycleBusy = false }
        do {
            try await command(runner)
            lastError = nil
            banners?.dismiss(key: "gateway")
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("gateway", error.localizedDescription)
        }
    }
}

struct GatewayView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

    @Environment(BannerCenter.self) private var banners: BannerCenter?

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
        .navigationTitle("Gateway & Messaging")
        .dismissesBanner("gateway", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (matching Cron/Profiles).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = GatewayHarness(client: client, runner: runner)
            h.banners = banners
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: GatewayHarness) -> some View {
        // The status header spans the full width above the split, so opening the
        // detail panel narrows only the platform list — the header stays uncramped.
        // The split is reachable only from the desktop window's Browse sidebar
        // (macOS + iPad); the iPhone shell has no Browse. `PlatformSplit` is a
        // resizable `HSplitView` on macOS, an `HStack`+`Divider` on iPad — no `#if`.
        VStack(spacing: 0) {
            statusHeader(harness: harness)
            Divider()
            PlatformSplit(showsSecondary: harness.selectedItem != nil) {
                platformList(harness: harness)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                detailPane(harness: harness)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
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
        // Hard errors route to the top-of-window strip; only the capability
        // warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresEnvAPI,
                feature: "Gateway & Messaging via Hermes dashboard",
                version: hermesVersion
            ),
            severity: .warning
        )
    }

    // MARK: - Status header

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

    // MARK: - Platform list (primary pane)

    @ViewBuilder
    private func platformList(harness: GatewayHarness) -> some View {
        List(selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            ForEach(harness.listItems) { item in
                row(for: item)
                    .tag(item.id)
                    .contentShape(Rectangle())
                    // Select on tap. macOS expands via `List(selection:)`, but a
                    // plain iOS/iPad List doesn't honor selection outside edit
                    // mode, so without this an iPad row can't open the panel.
                    .onTapGesture { harness.selectionID = item.id }
            }
        }
        .overlay {
            if harness.listItems.isEmpty, !harness.isLoading {
                ContentUnavailableView(
                    "No platforms",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("No messaging platforms are reported for this gateway.")
                )
            }
        }
    }

    @ViewBuilder
    private func row(for item: GatewayListItem) -> some View {
        switch item {
        case let .platform(group):
            PlatformListRow(group: group)
        case let .statusOnly(row):
            StatusOnlyListRow(row: row)
        }
    }

    // MARK: - Detail pane (secondary)

    // Rendered only while a platform is selected — `PlatformSplit`'s
    // `showsSecondary` gate hides this pane entirely otherwise, so there's no
    // unselected placeholder branch.
    @ViewBuilder
    private func detailPane(harness: GatewayHarness) -> some View {
        switch harness.selectedItem {
        case let .platform(group):
            PlatformDetailEditor(
                group: group,
                hasRunner: harness.hasRunner,
                gatewayRunning: harness.isGatewayRunning,
                restartBusy: harness.restartBusy,
                busy: harness.busy,
                remaskToken: harness.refreshToken,
                onSave: { key, value in Task { await harness.save(key: key, value: value) } },
                onDelete: { key in Task { await harness.delete(key: key) } },
                reveal: { key in await harness.revealValue(key: key) },
                onRestart: { Task { await harness.restartGateway() } },
                onFocus: { harness.selectionID = group.id }
            )
        case let .statusOnly(row):
            StatusOnlyDetail(row: row)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(harness: GatewayHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload the gateway status and messaging platforms")

            Button { Task { await harness.start() } } label: {
                Label("Start", systemImage: "play")
            }
            .disabled(!harness.hasRunner || harness.lifecycleBusy || harness.isRunning)
            .help("Start the gateway service")

            Button { Task { await harness.stop() } } label: {
                Label("Stop", systemImage: "stop")
            }
            .disabled(!harness.hasRunner || harness.lifecycleBusy || !harness.isRunning)
            .help("Stop the gateway service")

            Button { Task { await harness.restart() } } label: {
                Label("Restart", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!harness.hasRunner || harness.lifecycleBusy || !harness.isRunning)
            .help("Restart the gateway service")

            Button { Task { await harness.install() } } label: {
                Label("Install", systemImage: "square.and.arrow.down")
            }
            .disabled(!harness.hasRunner || harness.lifecycleBusy)
            .help("Install the gateway as a background service")

            Button { showUninstallConfirm = true } label: {
                Label("Uninstall", systemImage: "trash")
            }
            .disabled(!harness.hasRunner || harness.lifecycleBusy)
            .help("Uninstall the gateway background service")
        }
    }
}

/// Connection-state → colour, shared by the list pills and the detail header.
private func gatewayStateColor(_ state: String?) -> Color {
    switch state {
    case "connected": return .green
    case "connecting": return .orange
    case "error": return .red
    default: return .secondary
    }
}

/// A small connection-state pill, or "unknown" when `/api/status` didn't report
/// the platform.
private struct ConnectionPill: View {
    let state: String?

    var body: some View {
        Text(state ?? "unknown")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(gatewayStateColor(state).opacity(0.15), in: Capsule())
            .foregroundStyle(gatewayStateColor(state))
    }
}

/// One editable-platform row in the primary list: icon, name (+ error detail),
/// connection pill, and a configured indicator. Lifted from the old
/// `MessagingPlatformCard.header`.
private struct PlatformListRow: View {
    let group: MessagingPlatformGroup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.headline)
                // The live state itself shows in the pill; the subtitle surfaces
                // the error detail Hermes pairs with a failed state.
                if let message = group.connection?.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            ConnectionPill(state: group.connection?.state)
            configuredIndicator
        }
        .padding(.vertical, 4)
    }

    private var configuredIndicator: some View {
        Image(systemName: group.isConfigured ? "checkmark.seal.fill" : "circle")
            .foregroundStyle(group.isConfigured ? Color.green : Color.secondary)
            .help(group.isConfigured ? "Configured" : "Not configured")
            .accessibilityLabel(group.isConfigured ? "Configured" : "Not configured")
    }
}

/// One status-only row: a gateway-reported platform with no editable messaging
/// env var (config.yaml-only). Name + connection pill only.
private struct StatusOnlyListRow: View {
    let row: GatewayPlatformRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                if let message = row.platform.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            ConnectionPill(state: row.platform.state)
        }
        .padding(.vertical, 4)
    }
}

/// The selected editable platform's detail pane: the per-field editors, a
/// setup-guide link, and a contextual gateway Restart button. Lifted from the
/// old `MessagingPlatformCard` expanded body into the side panel.
private struct PlatformDetailEditor: View {
    let group: MessagingPlatformGroup
    let hasRunner: Bool
    let gatewayRunning: Bool
    let restartBusy: Bool
    let busy: Set<String>
    let remaskToken: Int
    let onSave: (String, String) -> Void
    let onDelete: (String) -> Void
    let reveal: (String) async -> String?
    let onRestart: () -> Void
    let onFocus: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                ForEach(group.fields) { field in
                    MessagingFieldRow(
                        field: field,
                        busy: busy.contains(field.envVar.name),
                        remaskToken: remaskToken,
                        onSave: { value in onSave(field.envVar.name, value) },
                        onDelete: { onDelete(field.envVar.name) },
                        reveal: { await reveal(field.envVar.name) },
                        onFocus: onFocus
                    )
                }
                restartRow
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reset every field's typed/revealed draft when switching platforms.
        .id(group.id)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: group.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(group.displayName)
                .font(.title3.weight(.semibold))
            Spacer()
            ConnectionPill(state: group.connection?.state)
        }
    }

    @ViewBuilder
    private var restartRow: some View {
        HStack {
            if let docURL = group.docURL, let link = URL(string: docURL) {
                Link(destination: link) {
                    Label("Setup guide", systemImage: "link")
                        .font(.caption)
                }
            }
            Spacer()
            Button {
                onRestart()
            } label: {
                if restartBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Restart gateway", systemImage: "arrow.clockwise.circle")
                }
            }
            .disabled(!hasRunner || !gatewayRunning || restartBusy)
            .help(gatewayRunning
                ? "Restart the gateway so saved credentials take effect"
                : "Start the gateway to apply saved credentials")
        }
        .padding(.top, 2)
    }
}

/// The selected status-only platform's detail pane: its connection state plus a
/// note that it's configured outside Talaria (config.yaml) with no editable
/// variables.
private struct StatusOnlyDetail: View {
    let row: GatewayPlatformRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(row.name)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    ConnectionPill(state: row.platform.state)
                }
                Divider()
                if let message = row.platform.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Text("This platform is configured outside Talaria (in the Hermes `config.yaml`) and has no editable messaging variables. Talaria shows its live connection state only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(row.id)
    }
}

/// One field editor in the detail pane: a friendly label, a `SecureField`+Reveal
/// eye for secrets (plain `TextField` otherwise), the raw var name +
/// description/doc-link as a caption, and per-field Save / Delete. The
/// reveal/draft lifecycle mirrors `EnvVarRow`. Moved verbatim from the old
/// `MessagingView.swift`.
private struct MessagingFieldRow: View {
    let field: MessagingPlatformGroup.Field
    let busy: Bool
    /// Bumped per refresh so the field re-masks any revealed secret.
    let remaskToken: Int
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let reveal: () async -> String?
    let onFocus: () -> Void

    @State private var draft: String = ""
    @State private var confirmingDelete = false
    @FocusState private var fieldFocused: Bool

    private var envVar: DashboardEnvVar { field.envVar }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(field.label)
                    .font(.subheadline.weight(.medium))
                if field.required {
                    Text("Required")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 4) {
                // The eye fetches a set var's value on demand — needed because
                // Messaging has no `.env` file reader (unlike Environment) and
                // Hermes masks non-password values too (`mask_secret` fully
                // redacts short ones like an allowed-users list), so this is the
                // only way to view a set field. `RevealableSecretField` shows the
                // eye for any secret, and for a set non-secret as a one-way
                // "load value".
                RevealableSecretField(
                    text: $draft,
                    placeholder: placeholder,
                    isSecret: envVar.isPassword,
                    canReveal: envVar.isSet,
                    reveal: reveal,
                    focus: $fieldFocused,
                    onFocus: onFocus,
                    remaskToken: remaskToken
                )
                saveButton
                if envVar.isSet { deleteButton }
            }

            caption
        }
        .padding(.vertical, 4)
        // Clear the typed/revealed draft once a save lands: a successful save
        // refreshes the harness, reloading this var with its new redacted value,
        // so the change fires here. A *failed* save doesn't refresh, so the
        // user's input is preserved to retry. The field re-masks itself when the
        // draft empties.
        .onChange(of: envVar.redactedValue) { _, _ in
            draft = ""
        }
        .alert("Delete \(envVar.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the variable from the Hermes host's .env file.")
        }
    }

    /// Placeholder = the current (redacted) value greyed when set, otherwise a
    /// type hint. An empty `draft` therefore reads as "keep the current value".
    private var placeholder: String {
        if let redacted = envVar.redactedValue, !redacted.isEmpty {
            return redacted
        }
        return "Value"
    }

    private var saveButton: some View {
        Button {
            onSave(draft)
        } label: {
            Image(systemName: "checkmark.circle")
        }
        .buttonStyle(.borderless)
        // Bind Cmd+Return only on the focused field. A panel expands all its
        // fields at once, so an unconditional shortcut would register several
        // identical bindings and SwiftUI would resolve Cmd+Return to a single
        // (possibly disabled, possibly wrong) field's Save. Environment's
        // EnvVarRow could bind it unconditionally because only one row expands.
        .keyboardShortcut(fieldFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(busy || draft.isEmpty)
        .accessibilityLabel("Save")
        .help("Save \(field.label)")
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(busy)
        .accessibilityLabel("Delete")
        .help("Delete \(field.label)")
    }

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(envVar.name)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if !envVar.description.isEmpty {
                Text(envVar.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let url = envVar.url, let link = URL(string: url) {
                Link(destination: link) {
                    Label(url, systemImage: "link")
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
