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
        PlatformSplit(showsSecondary: harness.selected != nil) {
            primaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresEnvAPI,
                feature: "Environment management via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
        // When the selected row falls out of the visible set — the user typed a
        // non-matching search query or hid advanced vars — drop the selection so
        // the detail pane (and any revealed plaintext it shows) doesn't keep
        // rendering a row that's no longer in the list. `selected` reads the
        // unfiltered `vars`, so without this the secret would linger past its
        // row. Clearing `selectionID` also clears `revealed` via its `didSet`.
        .onChange(of: searchText) { _, _ in reconcileSelection(harness: harness) }
        .onChange(of: harness.showAdvanced) { _, _ in reconcileSelection(harness: harness) }
        .sheet(isPresented: $showingAddSheet) {
            AddCustomVarSheet { name, value in
                Task { await harness.add(key: name, value: value) }
            }
        }
    }

    /// Drops the selection if the selected var no longer passes the current
    /// search/advanced filter, keeping the detail pane in step with the list.
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
                            EnvVarRow(envVar: envVar).tag(envVar.name)
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

    // MARK: - Detail pane

    // Rendered only when a var is selected — `PlatformSplit`'s `showsSecondary`
    // gate hides this pane entirely otherwise.
    @ViewBuilder
    private func detailPane(harness: EnvironmentHarness) -> some View {
        if let envVar = harness.selected {
            EnvVarDetail(
                envVar: envVar,
                busy: harness.busy.contains(envVar.name),
                revealedValue: harness.revealed[envVar.name],
                onSave: { value in Task { await harness.save(key: envVar.name, value: value) } },
                onDelete: { Task { await harness.delete(key: envVar.name) } },
                onReveal: { Task { await harness.reveal(key: envVar.name) } }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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

/// One row in the grouped variable list: name, a lock glyph for secrets, a
/// set/unset indicator, and the redacted value (when set).
private struct EnvVarRow: View {
    let envVar: DashboardEnvVar

    var body: some View {
        HStack(spacing: 8) {
            if envVar.isPassword {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(envVar.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let redacted = envVar.redactedValue, !redacted.isEmpty {
                    Text(redacted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Image(systemName: envVar.isSet ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(envVar.isSet ? Color.green : Color.secondary)
        }
    }
}

private struct EnvVarDetail: View {
    let envVar: DashboardEnvVar
    let busy: Bool
    let revealedValue: String?
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void

    @State private var draft: String = ""
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if envVar.isPassword {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
                Text(envVar.name)
                    .font(.headline)
                    .textSelection(.enabled)
            }

            if !envVar.description.isEmpty {
                Text(envVar.description)
                    .font(.body)
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

            Divider()

            editor

            Divider()

            HStack(spacing: 8) {
                Button {
                    onSave(draft)
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(busy || draft.isEmpty)

                if envVar.isSet {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(busy)
                }

                if busy { ProgressView().controlSize(.small) }
            }

            Spacer()
        }
        .id(envVar.name)
        // Reset the draft whenever the selected var changes — the same view is
        // reused across selections (`.id` forces a fresh `@State`), but be
        // explicit so a stale secret can't carry over into another var's field.
        .onChange(of: envVar.name, initial: true) { _, _ in draft = "" }
        // Clear the typed draft once a save lands: a successful save refreshes
        // the harness, reloading this var with its new redacted value, so the
        // change fires here and the entered secret doesn't linger in `draft`.
        // A *failed* save doesn't refresh (it only sets the banner error), so
        // `redactedValue` is unchanged and the user's input is preserved to
        // retry. Matches how the screen clears revealed plaintext elsewhere.
        .onChange(of: envVar.redactedValue) { _, _ in draft = "" }
        .alert("Delete \(envVar.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the variable from the Hermes host's .env file.")
        }
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if envVar.isPassword {
                SecureField("New value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    if let revealed = revealedValue {
                        Text(revealed)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let redacted = envVar.redactedValue, !redacted.isEmpty {
                        Text(redacted)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Not set")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if envVar.isSet, revealedValue == nil {
                        Button {
                            onReveal()
                        } label: {
                            Label("Reveal", systemImage: "eye")
                        }
                        .disabled(busy)
                        .help("Reveal the current value")
                    }
                }
            } else {
                TextField("Value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                if let current = envVar.redactedValue, !current.isEmpty {
                    Text("Current: \(current)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !envVar.isSet {
                    Text("Not set")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
