import HermesKit
import SwiftUI

@MainActor
@Observable
final class EnvironmentHarness {
    var vars: [DashboardEnvVar] = []
    var isLoading: Bool = false
    var lastError: String?
    var selectionID: String?
    /// Names with an in-flight save/delete, so their detail controls disable
    /// while the request is outstanding. (Reveal has its own per-field spinner
    /// inside ``RevealableSecretField``.)
    var busy: Set<String> = []
    /// Hides `advanced` vars behind the toolbar toggle (off by default).
    var showAdvanced: Bool = false
    /// Bumped on every refresh so expanded rows re-mask any revealed secret —
    /// a revealed value must not stay in cleartext across a reload.
    private(set) var refreshToken: Int = 0

    private let client: DashboardClient
    /// Reads the Hermes `.env` directly (local fs / SSH `cat`) purely to
    /// enumerate user-named custom keys the dashboard's `GET /api/env` doesn't
    /// know about. Nil when no runner/transfer is wired (e.g. iPad-local) — the
    /// screen then shows only the known vars. All mutations still go through the
    /// dashboard API.
    private let fileReader: EnvFileReading?

    init(client: DashboardClient, fileReader: EnvFileReading? = nil) {
        self.client = client
        self.fileReader = fileReader
    }

    /// Name rule shared with Hermes (`save_env_value`): a leading letter or
    /// underscore, then letters / digits / underscores.
    static let customNamePattern = "^[A-Za-z_][A-Za-z0-9_]*$"

    var selected: DashboardEnvVar? {
        guard let id = selectionID else { return nil }
        return vars.first { $0.name == id }
    }

    func refresh() async {
        isLoading = true
        refreshToken &+= 1
        defer { isLoading = false }
        do {
            var merged = try await client.listEnvVars()
            lastError = nil
            // Enumerate user-named custom keys by reading the `.env` directly,
            // and append the ones the dashboard doesn't already know about
            // (known wins over file). A file-read failure is non-fatal — keep
            // the known vars and surface the reason as a banner note rather than
            // clobbering the list.
            if let fileReader {
                do {
                    let entries = try await fileReader.read()
                    let fileValues = Dictionary(
                        entries.map { ($0.key, $0.value) },
                        uniquingKeysWith: { _, last in last }
                    )
                    // Un-mask non-secret known vars from the `.env` truth: the
                    // dashboard redacts even non-secret values when they're short
                    // (e.g. `***`), but a user's own non-secret value should just
                    // be visible. Secrets stay masked (reveal-on-demand) so
                    // plaintext never lingers in the list.
                    merged = merged.map { envVar in
                        guard !envVar.isPassword, let value = fileValues[envVar.name] else { return envVar }
                        return DashboardEnvVar(
                            name: envVar.name,
                            isSet: envVar.isSet,
                            redactedValue: value,
                            description: envVar.description,
                            url: envVar.url,
                            category: envVar.category,
                            isPassword: envVar.isPassword,
                            tools: envVar.tools,
                            advanced: envVar.advanced
                        )
                    }
                    var seen = Set(merged.map(\.name))
                    for entry in entries where !seen.contains(entry.key) {
                        seen.insert(entry.key)
                        merged.append(DashboardEnvVar(
                            name: entry.key,
                            isSet: true,
                            // Custom vars are non-secret (`isPassword: false`), so
                            // store the real value: the placeholder shows it greyed
                            // and the user can see their own value (no eye toggle
                            // exists for non-secrets).
                            redactedValue: entry.value,
                            description: "",
                            url: nil,
                            category: "custom",
                            isPassword: false,
                            tools: [],
                            advanced: false
                        ))
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
            vars = merged
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Adds a user-named custom var. Validates the name against
    /// ``customNamePattern`` (Hermes rejects anything else server-side too),
    /// then reuses ``save(key:value:)`` so the `PUT /api/env` + refresh path is
    /// identical to editing a known var. The new key surfaces under **Custom**
    /// after the refresh.
    func add(key: String, value: String) async {
        let name = key.trimmingCharacters(in: .whitespaces)
        guard name.range(of: Self.customNamePattern, options: .regularExpression) != nil else {
            lastError = "“\(name)” isn’t a valid variable name. Use a letter or underscore, then letters, digits, or underscores."
            return
        }
        await save(key: name, value: value)
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
    /// field's view state, so it can't linger past that row — no harness-side
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
}

struct EnvironmentView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?
    /// Profile-scoped admin runner used to resolve the `.env` path
    /// (`hermes config env-path`). Nil leaves custom-var enumeration off.
    let runner: HermesAdminRunning?
    /// SSH transfer for reading a remote profile's `.env`; nil for local
    /// profiles and for the system-ssh macOS path (which falls back to the
    /// `sftp` subprocess inside ``HermesEnvFileReader`` — see
    /// ``canEnumerateCustomVars``).
    let snapshotTransfer: RemoteSnapshotTransfer?
    /// The window's profile — its `kind` selects the local-fs vs SSH read path.
    let profile: ServerProfile?

    @State private var harness: EnvironmentHarness?
    @State private var searchText: String = ""
    @State private var showingAddSheet = false

    init(
        client: DashboardClient?,
        hermesVersion: HermesVersion? = nil,
        runner: HermesAdminRunning? = nil,
        snapshotTransfer: RemoteSnapshotTransfer? = nil,
        profile: ServerProfile? = nil
    ) {
        self.client = client
        self.hermesVersion = hermesVersion
        self.runner = runner
        self.snapshotTransfer = snapshotTransfer
        self.profile = profile
    }

    /// Whether the `.env` read path is actually available. Needs a runner to
    /// resolve the path (`hermes config env-path`), plus a way to read the file:
    /// a local profile (filesystem), an injected SSH transfer (NIO), or — on
    /// macOS — the `sftp` subprocess fallback for a system-ssh remote (the same
    /// fallback ``HermesConfigReader`` uses). Gating Add on this is correct: with
    /// the remote read now available, a custom var written via Add re-appears on
    /// refresh.
    private var canEnumerateCustomVars: Bool {
        guard runner != nil else { return false }
        if profile?.kind == .local || snapshotTransfer != nil { return true }
        #if os(macOS)
        return profile?.kind == .ssh
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "key",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Environment")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil (matching the
        // other dashboard surfaces).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            // Only build a file reader when the read path is actually available
            // (see `canEnumerateCustomVars`). Without it the screen shows known
            // vars only — no persistent "no SSH transfer" banner.
            let reader: EnvFileReading? = canEnumerateCustomVars
                ? HermesEnvFileReader(
                    runner: runner,
                    snapshotTransfer: snapshotTransfer,
                    isLocal: profile?.kind == .local,
                    profile: profile
                )
                : nil
            let h = EnvironmentHarness(client: client, fileReader: reader)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: EnvironmentHarness) -> some View {
        primaryPane(harness: harness)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbar(harness: harness) }
            .manageBanner(
                harness.lastError ?? capabilityBanner(
                    .requiresEnvAPI,
                    feature: "Environment management via Hermes dashboard",
                    version: hermesVersion
                ),
                severity: harness.lastError != nil ? .error : .warning
            )
            // When the selected (expanded) row falls out of the visible set — the
            // user typed a non-matching search query or hid advanced vars —
            // collapse it so its expanded controls (and any revealed plaintext)
            // stop rendering for a row that's no longer in the list. `selected`
            // reads the unfiltered `vars`, so without this the secret would
            // linger past its row. Clearing `selectionID` collapses the row,
            // and `EnvVarRow`'s `onChange(of: isExpanded)` then drops the
            // revealed plaintext (`draft = ""`), re-masking the field.
            .onChange(of: searchText) { _, _ in reconcileSelection(harness: harness) }
            .onChange(of: harness.showAdvanced) { _, _ in reconcileSelection(harness: harness) }
            .sheet(isPresented: $showingAddSheet) {
                AddCustomVarSheet { name, value in
                    Task { await harness.add(key: name, value: value) }
                }
            }
    }

    /// Drops the selection if the selected var no longer passes the current
    /// search/advanced filter, collapsing a row that's been filtered out.
    private func reconcileSelection(harness: EnvironmentHarness) {
        if let selected = harness.selected, !matchesFilter(selected, harness: harness) {
            harness.selectionID = nil
        }
    }

    // MARK: - Primary pane

    @ViewBuilder
    private func primaryPane(harness: EnvironmentHarness) -> some View {
        List(selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            ForEach(EnvCategory.allCases) { category in
                let rows = filteredVars(harness: harness, category: category)
                if !rows.isEmpty {
                    Section(category.displayName) {
                        ForEach(rows) { envVar in
                            EnvVarRow(
                                envVar: envVar,
                                isExpanded: harness.selectionID == envVar.name,
                                busy: harness.busy.contains(envVar.name),
                                onSave: { value in Task { await harness.save(key: envVar.name, value: value) } },
                                onDelete: { Task { await harness.delete(key: envVar.name) } },
                                reveal: { await harness.revealValue(key: envVar.name) },
                                remaskToken: harness.refreshToken,
                                onFocus: { harness.selectionID = envVar.name }
                            )
                            .tag(envVar.name)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter variables")
        .overlay {
            if harness.vars.isEmpty, !harness.isLoading {
                ContentUnavailableView("No variables", systemImage: "key")
            }
        }
    }

    /// Vars in `category` that pass the current filter. Unknown categories fall
    /// into `.other`.
    private func filteredVars(harness: EnvironmentHarness, category: EnvCategory) -> [DashboardEnvVar] {
        harness.vars.filter {
            EnvCategory(rawCategory: $0.category) == category && matchesFilter($0, harness: harness)
        }
    }

    /// Whether a var passes the search query and the advanced toggle — the
    /// single predicate behind both the list grouping and the selection
    /// reconciliation, so a row can't be visible in one and hidden in the other.
    private func matchesFilter(_ envVar: DashboardEnvVar, harness: EnvironmentHarness) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return (harness.showAdvanced || !envVar.advanced)
            && (query.isEmpty
                || envVar.name.lowercased().contains(query)
                || envVar.description.lowercased().contains(query))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(harness: EnvironmentHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: Binding(
                get: { harness.showAdvanced },
                set: { harness.showAdvanced = $0 }
            )) {
                Label("Show advanced", systemImage: "slider.horizontal.3")
            }
            .help("Show advanced (rarely-needed) variables")

            // Adding a custom var only makes sense when the file reader can
            // enumerate it back (the dashboard's GET /api/env won't list custom
            // keys), so gate the button on the read path being available — not
            // just a runner. Otherwise a macOS system-ssh remote would offer an
            // Add that writes a var which then never re-appears.
            if canEnumerateCustomVars {
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add variable", systemImage: "plus")
                }
                .accessibilityLabel("Add variable")
                .help("Add a custom environment variable")
            }

            Button {
                Task { await harness.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload the environment variables")
        }
    }
}

/// Sheet for creating a user-named custom variable. The name is validated
/// (and `is_managed()` rejections surfaced) by ``EnvironmentHarness/add(key:value:)``
/// through the screen's banner — the value field is a plain `TextField` because
/// custom vars are `isPassword: false` and reveal still works after creation.
private struct AddCustomVarSheet: View {
    let onAdd: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var value: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Variable")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("MY_API_BASE", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                TextField("Value", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    onAdd(name, value)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}

/// App-side category → display-name mapping (a UI concern, kept here like
/// `PluginsView`'s status-pill mapping). `allCases` defines the section order
/// in the list; `.other` captures any category Hermes adds that isn't modeled
/// yet so its vars still appear.
enum EnvCategory: String, CaseIterable, Identifiable {
    case provider
    case messaging
    case tool
    case skill
    case setting
    case custom
    case other

    var id: String { rawValue }

    init(rawCategory: String) {
        self = EnvCategory(rawValue: rawCategory) ?? .other
    }

    var displayName: String {
        switch self {
        case .provider: return "Model Providers"
        case .messaging: return "Messaging Gateways"
        case .tool: return "Tools & Services"
        case .skill: return "Skills"
        case .setting: return "Settings"
        case .custom: return "Custom"
        case .other: return "Other"
        }
    }
}

/// One inline-expanding row in the grouped variable list. Collapsed, it shows a
/// lock slot, the key name, and the editable value field on one line. Selected
/// (`isExpanded`) it grows in place to reveal the description, documentation
/// link, "Used by:" dependencies, and the Save / Delete controls — the content
/// that used to live in a separate detail pane.
private struct EnvVarRow: View {
    let envVar: DashboardEnvVar
    let isExpanded: Bool
    let busy: Bool
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let reveal: () async -> String?
    /// Bumped per refresh so the field re-masks any revealed secret.
    let remaskToken: Int
    /// Called when the value field gains focus, so the screen expands this row
    /// ("focusing any record expands it").
    let onFocus: () -> Void

    /// Lock slot width (12) + HStack spacing (8): the leading inset that aligns
    /// the expanded details under the key name rather than the lock icon.
    private static let keyInset: CGFloat = 20
    /// Fixed width of the trailing value column (field + eye + clear). The field
    /// flexes inside it, so toggling the icons shrinks the field instead of
    /// displacing it.
    private static let valueColumnWidth: CGFloat = 240

    /// Typed replacement value. Empty means "keep the current value" — Save is
    /// disabled and the placeholder shows the existing (redacted) value.
    @State private var draft: String = ""
    @State private var confirmingDelete = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Fixed-width, opacity-gated lock slot so every key name shares
                // the same left edge whether or not the var is a secret.
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .opacity(envVar.isPassword ? 1 : 0)
                    .frame(width: 12)

                Text(envVar.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                // Fixed-width value column: the field flexes, icons take intrinsic
                // width, so toggling the eye/clear shrinks the field rather than
                // shoving it left.
                HStack(spacing: 4) {
                    // Eye only for secrets (non-secrets are un-masked inline by
                    // the `.env` file reader) and only once expanded.
                    RevealableSecretField(
                        text: $draft,
                        placeholder: placeholder,
                        isSecret: envVar.isPassword,
                        canReveal: envVar.isPassword && envVar.isSet,
                        reveal: reveal,
                        revealAvailable: isExpanded,
                        focus: $fieldFocused,
                        onFocus: onFocus,
                        remaskToken: remaskToken
                    )
                    if isExpanded, envVar.isSet { clearButton }
                }
                .frame(width: Self.valueColumnWidth, alignment: .leading)
            }

            if isExpanded {
                expandedContent
                    .padding(.leading, Self.keyInset)
            }
        }
        // Breathing room so row content (esp. the link/tools on the last row)
        // isn't flush against the list edges.
        .padding(.vertical, 6)
        .padding(.trailing, 4)
        // Drop the typed/revealed draft the moment the row collapses: a secret
        // must never linger past the row that asked for it. `RevealableSecretField`
        // re-masks itself when the draft empties.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { draft = "" }
        }
        // Clear the typed draft once a save lands: a successful save refreshes
        // the harness, reloading this var with its new redacted value, so the
        // change fires here and the entered secret doesn't linger in `draft`. A
        // *failed* save doesn't refresh (it only sets the banner error), so
        // `redactedValue` is unchanged and the user's input is preserved to retry.
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

    /// Placeholder = the current value (greyed) when set, otherwise a type hint.
    /// For a secret this is the redacted preview (`8515…MuJw`); for a non-secret
    /// it's the actual stored value.
    private var placeholder: String {
        if let redacted = envVar.redactedValue, !redacted.isEmpty {
            return redacted
        }
        return "Value"
    }

    @ViewBuilder
    private var expandedContent: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if !envVar.description.isEmpty {
                    Text(envVar.description)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                if let url = envVar.url, let link = URL(string: url) {
                    Link(destination: link) {
                        Label(url, systemImage: "link")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if !envVar.tools.isEmpty {
                    Text("Used by: \(envVar.tools.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if busy { ProgressView().controlSize(.small) }
            saveButton
        }
    }

    private var saveButton: some View {
        Button {
            onSave(draft)
        } label: {
            Label("Save", systemImage: "checkmark.circle")
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(busy || draft.isEmpty)
    }

    /// Clear-style destructive control, styled like the Configuration editor's
    /// clear button but with delete semantics (confirmation + `onDelete`). Sits
    /// beside the value field (expanded, set vars only), not in `expandedContent`.
    private var clearButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(busy)
        .accessibilityLabel("Delete")
        .help("Delete the variable")
    }
}
