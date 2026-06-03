import HermesKit
import SwiftUI

@MainActor
@Observable
final class MessagingHarness {
    /// Per-platform cards, rebuilt on every refresh from the messaging env vars
    /// fused with the gateway status.
    var groups: [MessagingPlatformGroup] = []
    /// Last `/api/status` payload (for the gateway connection pills). Nil when
    /// the status route fails — cards still render, pills show "unknown".
    var status: DashboardStatus?
    var isLoading: Bool = false
    var lastError: String?
    /// The selected (expanded) platform card's `id`.
    var selectionID: String?
    /// Env-var names with an in-flight save/delete, so their field controls
    /// disable while the request is outstanding. (Reveal has its own per-field
    /// spinner inside ``RevealableSecretField``.)
    var busy: Set<String> = []
    /// True while a gateway restart runs, so the Restart button disables.
    var restartBusy: Bool = false
    /// Bumped on every refresh so expanded fields re-mask any revealed secret —
    /// a revealed value must not stay in cleartext across a reload.
    private(set) var refreshToken: Int = 0

    private let client: DashboardClient
    /// Lifecycle writes (gateway restart) go through the CLI admin runner —
    /// there's no dashboard HTTP control route. Nil on the iPad-local path,
    /// where the Restart button stays disabled.
    private let runner: HermesAdminRunning?

    init(client: DashboardClient, runner: HermesAdminRunning?) {
        self.client = client
        self.runner = runner
    }

    var hasRunner: Bool { runner != nil }

    /// Whether the gateway is currently running, from the last `/api/status`.
    /// Restart is gated on this (matching `GatewayHarness.isRunning`): a
    /// `hermes gateway restart` against a stopped gateway errors rather than
    /// starting it, and Messaging offers no Start — that lives in Gateway,
    /// which picks up the saved env when it next starts.
    var isGatewayRunning: Bool { status?.gatewayRunning == true }

    /// Loads env vars + gateway status concurrently (the `ModelsHarness.refresh`
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save(key: String, value: String) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await client.setEnvVar(key: key, value: value)
            await refresh()
        } catch {
            lastError = error.localizedDescription
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
            return nil
        }
    }

    /// Restarts the gateway so a just-saved platform credential takes effect,
    /// then refreshes status. No-ops without a runner (no dashboard route).
    func restartGateway() async {
        guard let runner else { return }
        restartBusy = true
        defer { restartBusy = false }
        do {
            try await HermesGateway.restart(runner: runner)
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct MessagingView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?

    @State private var harness: MessagingHarness?

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
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Messaging")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil (matching the
        // other dashboard surfaces).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = MessagingHarness(client: client, runner: runner)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: MessagingHarness) -> some View {
        platformList(harness: harness)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbar(harness: harness) }
            .manageBanner(
                harness.lastError ?? capabilityBanner(
                    .requiresEnvAPI,
                    feature: "Messaging setup via Hermes dashboard",
                    version: hermesVersion
                ),
                severity: harness.lastError != nil ? .error : .warning
            )
    }

    @ViewBuilder
    private func platformList(harness: MessagingHarness) -> some View {
        List(selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            ForEach(harness.groups) { group in
                MessagingPlatformCard(
                    group: group,
                    isExpanded: harness.selectionID == group.id,
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
                .tag(group.id)
            }
        }
        .overlay {
            if harness.groups.isEmpty, !harness.isLoading {
                ContentUnavailableView(
                    "No messaging platforms",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("This Hermes host reports no messaging variables.")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: MessagingHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await harness.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload the messaging platforms")
        }
    }
}

/// One inline-expanding platform card. Collapsed: icon, name, connection pill,
/// and a configured indicator. Selected (`isExpanded`): the per-field editors
/// plus a gateway Restart button.
private struct MessagingPlatformCard: View {
    let group: MessagingPlatformGroup
    let isExpanded: Bool
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
        VStack(alignment: .leading, spacing: 10) {
            header

            if isExpanded {
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
        }
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        // Expand on a header tap. macOS already expands via `List(selection:)`,
        // but a plain iOS List doesn't honor selection outside edit mode and a
        // collapsed card has nothing focusable, so without this an iOS card
        // can't be opened. Re-selecting an already-open card is a no-op.
        .onTapGesture { onFocus() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: group.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.displayName)
                    .font(.headline)
                // The live state itself shows in `connectionPill`; the subtitle
                // surfaces the error detail Hermes pairs with a failed state
                // (mirroring GatewayView's Error column) rather than repeating it.
                if let message = group.connection?.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            connectionPill
            configuredIndicator
        }
    }

    /// Live gateway connection state, or "unknown" when `/api/status` didn't
    /// report this platform.
    private var connectionPill: some View {
        let state = group.connection?.state
        return Text(state ?? "unknown")
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Self.stateColor(state).opacity(0.15), in: Capsule())
            .foregroundStyle(Self.stateColor(state))
    }

    private var configuredIndicator: some View {
        Image(systemName: group.isConfigured ? "checkmark.seal.fill" : "circle")
            .foregroundStyle(group.isConfigured ? Color.green : Color.secondary)
            .help(group.isConfigured ? "Configured" : "Not configured")
            .accessibilityLabel(group.isConfigured ? "Configured" : "Not configured")
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
                : "Start the gateway from the Gateway screen to apply saved credentials")
        }
        .padding(.top, 2)
    }

    /// Connection-state → colour, mirroring `GatewayView.platformStateColor`.
    private static func stateColor(_ state: String?) -> Color {
        switch state {
        case "connected": return .green
        case "connecting": return .orange
        case "error": return .red
        default: return .secondary
        }
    }
}

/// One field editor inside an expanded platform card: a friendly label, a
/// `SecureField`+Reveal eye for secrets (plain `TextField` otherwise), the raw
/// var name + description/doc-link as a caption, and per-field Save / Delete.
/// The reveal/draft lifecycle mirrors `EnvVarRow`.
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
        // Bind Cmd+Return only on the focused field. A card expands all its
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
