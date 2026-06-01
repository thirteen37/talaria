import HermesKit
import SwiftUI

@MainActor
@Observable
final class EnvironmentHarness {
    var vars: [DashboardEnvVar] = []
    var isLoading: Bool = false
    var lastError: String?
    var selectionID: String? {
        didSet {
            // Drop every revealed plaintext when the selection moves: a secret
            // is scoped to the row that asked for it, so re-selecting a
            // previously-revealed var must trigger a fresh (rate-limited)
            // reveal rather than re-displaying cached plaintext from memory.
            if oldValue != selectionID { revealed = [:] }
        }
    }
    /// Names with an in-flight save/delete/reveal, so their detail controls
    /// disable while the request is outstanding.
    var busy: Set<String> = []
    /// Revealed plaintext values keyed by var name. Cleared on every refresh and
    /// whenever the selection changes, so a secret never lingers on screen past
    /// the row that asked for it.
    var revealed: [String: String] = [:]
    /// Hides `advanced` vars behind the toolbar toggle (off by default).
    var showAdvanced: Bool = false

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
        defer { isLoading = false }
        do {
            var merged = try await client.listEnvVars()
            revealed = [:]
            lastError = nil
            // Enumerate user-named custom keys by reading the `.env` directly,
            // and append the ones the dashboard doesn't already know about
            // (known wins over file). A file-read failure is non-fatal — keep
            // the known vars and surface the reason as a banner note rather than
            // clobbering the list.
            if let fileReader {
                do {
                    let entries = try await fileReader.read()
                    var seen = Set(merged.map(\.name))
                    for entry in entries where !seen.contains(entry.key) {
                        seen.insert(entry.key)
                        merged.append(DashboardEnvVar(
                            name: entry.key,
                            isSet: true,
                            redactedValue: redactEnvValue(entry.value),
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

    func reveal(key: String) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let value = try await client.revealEnvVar(key: key)
            // Only store the plaintext if this var is still selected: if the
            // user moved to another row during the await, `selectionID`'s
            // `didSet` already cleared `revealed`, and writing here would leave
            // a secret lingering in memory keyed to the now-deselected var —
            // breaking the "never lingers past its row" invariant.
            if selectionID == key { revealed[key] = value }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
    /// profiles (and the system-ssh macOS path, where there's no transfer to
    /// read a remote `.env` with — see ``canEnumerateCustomVars``).
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
    /// resolve the path (`hermes config env-path`), plus either a local profile
    /// (filesystem read) or an SSH transfer (remote `cat`). On the macOS
    /// system-ssh remote path `snapshotTransfer` is nil, so custom-var
    /// enumeration — and the Add button — stay off there rather than failing
    /// every refresh with a "no SSH transfer" banner and offering an Add that
    /// writes vars which never re-appear.
    private var canEnumerateCustomVars: Bool {
        runner != nil && (profile?.kind == .local || snapshotTransfer != nil)
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
                    isLocal: profile?.kind == .local
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
            // linger past its row. Clearing `selectionID` also clears `revealed`
            // via its `didSet`.
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
                                revealedValue: harness.revealed[envVar.name],
                                onSave: { value in Task { await harness.save(key: envVar.name, value: value) } },
                                onDelete: { Task { await harness.delete(key: envVar.name) } },
                                onReveal: { Task { await harness.reveal(key: envVar.name) } },
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
    let revealedValue: String?
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    /// Called when the value field gains focus, so the screen expands this row
    /// ("focusing any record expands it").
    let onFocus: () -> Void

    /// Typed replacement value. Empty means "keep the current value" — Save is
    /// disabled and the placeholder shows the existing (redacted) value.
    @State private var draft: String = ""
    /// Whether the secret is shown in cleartext (eye toggle). Always false for
    /// non-secret vars, which render a plain `TextField` regardless.
    @State private var showKey: Bool = false
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

                valueField
                    .frame(maxWidth: 240)

                if envVar.isPassword, isExpanded {
                    revealEye
                }
            }

            if isExpanded {
                expandedContent
            }
        }
        // Drop any revealed plaintext and typed draft the moment the row
        // collapses: a secret must never linger past the row that asked for it.
        // The per-row analogue of `selectionID.didSet` clearing `harness.revealed`.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                draft = ""
                showKey = false
            }
        }
        // Clear the typed draft once a save lands: a successful save refreshes
        // the harness, reloading this var with its new redacted value, so the
        // change fires here and the entered secret doesn't linger in `draft`. A
        // *failed* save doesn't refresh (it only sets the banner error), so
        // `redactedValue` is unchanged and the user's input is preserved to retry.
        .onChange(of: envVar.redactedValue) { _, _ in
            draft = ""
            showKey = false
        }
        // The eye's `onReveal()` is async; the plaintext arrives here once the
        // harness fetches it. Drop it into the field and switch to cleartext so
        // the real value lands in the box for editing. When it clears back to nil
        // — a toolbar Refresh wipes `harness.revealed` while the row stays
        // expanded — mirror that by dropping the plaintext from the field too, so
        // a revealed secret never survives a refresh ("cleared on every refresh").
        .onChange(of: revealedValue) { _, newValue in
            if let newValue {
                draft = newValue
                showKey = true
            } else {
                draft = ""
                showKey = false
            }
        }
        .alert("Delete \(envVar.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the variable from the Hermes host's .env file.")
        }
    }

    /// The value editor shared by collapsed and expanded rows: a `SecureField`
    /// while a secret is hidden, a `TextField` otherwise. The placeholder shows
    /// the current (redacted) value greyed, so an empty `draft` reads as "keep".
    @ViewBuilder
    private var valueField: some View {
        Group {
            if envVar.isPassword, !showKey {
                SecureField(placeholder, text: $draft)
            } else {
                TextField(placeholder, text: $draft)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.caption, design: .monospaced))
        .focused($fieldFocused)
        .onChange(of: fieldFocused) { _, focused in
            if focused { onFocus() }
        }
    }

    /// Placeholder = the current value (greyed) when set, otherwise a type hint.
    /// For a secret this is the redacted preview (`8515…MuJw`); for a non-secret
    /// it's the actual stored value.
    private var placeholder: String {
        if let redacted = envVar.redactedValue, !redacted.isEmpty {
            return redacted
        }
        return envVar.isPassword ? "New value" : "Value"
    }

    /// Icon-only reveal toggle modelled on `CustomEndpointForm.apiKeyField`.
    private var revealEye: some View {
        Button {
            toggleReveal()
        } label: {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: showKey ? "eye.slash" : "eye")
            }
        }
        .buttonStyle(.borderless)
        .disabled(busy)
        .accessibilityLabel(showKey ? "Hide value" : "Show value")
        .help(showKey ? "Hide the value" : "Reveal the current value")
    }

    /// One control for both "show what I typed" and "fetch the stored secret".
    /// When hidden with a set var and an empty draft, fetch the plaintext from
    /// the dashboard; otherwise just flip visibility of the typed value.
    private func toggleReveal() {
        if showKey {
            showKey = false
            return
        }
        if envVar.isSet, draft.isEmpty {
            onReveal()           // async: lands in `draft` via `.onChange(of: revealedValue)`
        } else {
            showKey = true
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !envVar.description.isEmpty {
            Text(envVar.description)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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

        HStack(spacing: 8) {
            Button {
                onSave(draft)
            } label: {
                Label("Save", systemImage: "checkmark.circle")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(busy || draft.isEmpty)

            if envVar.isSet {
                deleteButton
            }

            if busy { ProgressView().controlSize(.small) }
        }
    }

    /// Clear-style destructive control, styled like the Configuration editor's
    /// clear button but with delete semantics (confirmation + `onDelete`).
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
        .help("Delete the variable")
    }
}
