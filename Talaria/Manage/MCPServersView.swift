import HermesKit
import SwiftUI

// MARK: - Draft

/// One editable `KEY=VALUE` row (stdio env block). `id` is stable so SwiftUI
/// keeps focus while typing; never derived from the key (which churns).
struct KeyValuePair: Identifiable, Equatable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
}

/// Edit/add form state. The dashboard create body infers the transport from
/// url-vs-command, so the draft just tracks which the user is filling in.
struct MCPServerDraft: Equatable {
    var name: String = ""
    var transport: MCPTransport = .stdio

    // stdio
    var command: String = ""
    /// Newline-separated argv (one per line), split on commit. Newlines only —
    /// never whitespace — so an argument containing spaces survives the round-trip.
    var argsText: String = ""
    var env: [KeyValuePair] = []

    // remote (http/sse)
    var url: String = ""
    /// `""` (none) | `"oauth"` | `"header"`.
    var auth: String = ""
}

// MARK: - Harness

@MainActor
@Observable
final class MCPServersHarness {
    var servers: [DashboardMCPServer] = []
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// the surface id so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    var isLoading: Bool = false
    var selectionID: DashboardMCPServer.ID?
    var draft: MCPServerDraft?
    /// The server being edited via the delete+re-add round-trip, so a committed
    /// draft removes the original first and can re-apply its prior `enabled`
    /// state. Nil for a plain Add.
    var editingServer: DashboardMCPServer?

    /// Latest `test` result, keyed to `testResultName` so the detail pane only
    /// shows it for the server it came from.
    var testResult: DashboardMCPTestResult?
    var testResultName: String?
    /// Names with an in-flight test, so their Enabled toggle disables meanwhile.
    var testing: Set<String> = []

    var catalog: [DashboardMCPCatalogEntry] = []
    var catalogLoading: Bool = false
    var showCatalog: Bool = false
    /// Catalog names with an in-flight install.
    var installing: Set<String> = []

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    var selectedServer: DashboardMCPServer? {
        guard let id = selectionID else { return nil }
        return servers.first { $0.id == id }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await client.listMCPServers()
            lastError = nil
            banners?.dismiss(key: "mcp")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("mcp", error.localizedDescription)
        }
    }

    func beginAdd() {
        draft = MCPServerDraft()
        editingServer = nil
        selectionID = nil
        showCatalog = false
    }

    func cancelAdd() {
        draft = nil
        editingServer = nil
    }

    /// Clears every state var that opens the secondary pane (draft, selection,
    /// catalog) in one call — used by the iPhone push to deselect the list when
    /// the pushed detail/editor/catalog page is popped via Back.
    func closeSecondary() {
        draft = nil
        editingServer = nil
        selectionID = nil
        showCatalog = false
    }

    /// Loads a server row into the draft for the delete+re-add "Edit" path.
    /// stdio env values come back **redacted**, so they're intentionally not
    /// prefilled — the editor notes that secrets must be re-entered to keep
    /// them (a blank value drops that key on re-add).
    func beginEdit(_ server: DashboardMCPServer) {
        var draft = MCPServerDraft(name: server.name)
        if server.command != nil {
            draft.transport = .stdio
            draft.command = server.command ?? ""
            // One arg per line, not space-joined: an argument that legitimately
            // contains a space (e.g. a path like "/Users/me/My Files") must
            // round-trip intact, and the commit splits on newlines only.
            draft.argsText = (server.args ?? []).joined(separator: "\n")
            draft.env = (server.env ?? [:])
                .keys
                .sorted()
                .map { KeyValuePair(key: $0, value: "") }
        } else {
            draft.transport = .http
            draft.url = server.url ?? ""
            draft.auth = server.auth ?? ""
        }
        self.draft = draft
        editingServer = server
        showCatalog = false
    }

    /// Commits an add (or edit = delete-then-add). Re-throws nothing — failures
    /// land in `lastError` and leave the draft open to retry.
    ///
    /// Edit is a non-atomic delete-then-add against an API with no in-place
    /// update. To keep the failure path honest:
    ///   - `editingServer` is cleared the instant the delete succeeds, so a
    ///     retry after a failed re-add is a plain add (it won't try to delete a
    ///     server that's already gone and 404).
    ///   - `refresh()` runs on *both* paths, so a delete that lands without its
    ///     re-add is reflected in the table immediately rather than lingering as
    ///     a phantom row until the next manual refresh.
    ///   - the original `enabled` state is re-applied after the re-add (a new
    ///     server defaults to enabled). The tool-selection allowlist can't be
    ///     restored — the dashboard exposes no route to set it — so the editor
    ///     warns when the edited server had one.
    func commit(_ draft: MCPServerDraft) async {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let original = editingServer
        do {
            if let original {
                try await client.deleteMCPServer(name: original.name)
                editingServer = nil
            }
            switch draft.transport {
            case .stdio:
                // Split on newlines only (one arg per line) so an argument that
                // contains spaces survives the round-trip.
                let args = draft.argsText
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let env = envDict(from: draft.env)
                try await client.addMCPServer(
                    name: name,
                    command: draft.command.trimmingCharacters(in: .whitespaces),
                    args: args.isEmpty ? nil : args,
                    env: env.isEmpty ? nil : env
                )
            case .http:
                let auth = draft.auth.trimmingCharacters(in: .whitespaces)
                try await client.addMCPServer(
                    name: name,
                    url: draft.url.trimmingCharacters(in: .whitespaces),
                    auth: auth.isEmpty ? nil : auth
                )
            }
            // Re-apply the prior disabled state — a re-added server comes back
            // enabled by default, which would silently re-enable a server the
            // user had turned off.
            if original?.enabled == false {
                try await client.setMCPServerEnabled(name: name, enabled: false)
            }
            self.draft = nil
            await refresh()
        } catch {
            let message = error.localizedDescription
            // The delete may have already landed; refresh so the table reflects
            // reality instead of showing a server that no longer exists. refresh()
            // resets lastError on success, so re-assert the failure afterward —
            // otherwise a successful refresh would hide that the edit failed.
            await refresh()
            lastError = message
            banners?.surfaceError("mcp", message)
        }
    }

    func setEnabled(_ server: DashboardMCPServer, enabled: Bool) async {
        do {
            try await client.setMCPServerEnabled(name: server.name, enabled: enabled)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("mcp", error.localizedDescription)
        }
    }

    func delete(_ server: DashboardMCPServer) async {
        do {
            try await client.deleteMCPServer(name: server.name)
            if selectionID == server.id { selectionID = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("mcp", error.localizedDescription)
        }
    }

    /// Tests a server's connection. No refresh — the registry is unchanged; the
    /// tool list (or error) lands in `testResult` for the detail pane.
    func test(_ server: DashboardMCPServer) async {
        testing.insert(server.name)
        defer { testing.remove(server.name) }
        do {
            let result = try await client.testMCPServer(name: server.name)
            testResult = result
            testResultName = server.name
            // A reachable-but-failing probe returns ok:false with an error —
            // surface it on the banner too so it's visible without the pane.
            lastError = result.ok ? nil : result.error
            if result.ok {
                banners?.dismiss(key: "mcp")
            } else if let error = result.error {
                banners?.surfaceError("mcp", error)
            }
        } catch {
            testResult = nil
            testResultName = nil
            lastError = error.localizedDescription
            banners?.surfaceError("mcp", error.localizedDescription)
        }
    }

    func loadCatalog() async {
        catalogLoading = true
        defer { catalogLoading = false }
        do {
            catalog = try await client.listMCPCatalog()
            lastError = nil
            banners?.dismiss(key: "mcp")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("mcp", error.localizedDescription)
        }
    }

    func install(entry: DashboardMCPCatalogEntry, env: [String: String]) async {
        installing.insert(entry.name)
        defer { installing.remove(entry.name) }
        do {
            let result = try await client.installMCPCatalogEntry(name: entry.name, env: env.isEmpty ? nil : env)
            // Git-bootstrap entries (`needs_install`) clone in a detached
            // `mcp-install` action and return immediately with `background:true`;
            // the server isn't in the registry yet. Poll the action to completion
            // — `installing` stays set the whole time, so the row keeps its
            // spinner — then refresh so the new server actually appears.
            var failure: String?
            if result.background == true {
                let status = await waitForBackgroundInstall(action: result.action ?? "mcp-install")
                // A detached clone that fails flips `running` false with a
                // non-zero exit but never throws (the POST already returned 200),
                // so check the exit code and surface it — otherwise a failed
                // install is indistinguishable from a success.
                if let status, (status.exitCode ?? 0) != 0 {
                    let tail = status.lines.suffix(5).joined(separator: "\n")
                    failure = "Install of “\(entry.name)” failed (exit \(status.exitCode ?? -1))."
                        + (tail.isEmpty ? "" : "\n\(tail)")
                }
            } else if !result.ok {
                // Synchronous install that reported failure in-band (200 with
                // `ok:false`) rather than a non-2xx — surface it too, otherwise
                // the refresh below clears lastError and it reads as a success.
                failure = "Install of “\(entry.name)” failed."
            }
            await refresh()
            await loadCatalog()
            // Set the failure last: refresh()/loadCatalog() clear lastError on
            // success, which would otherwise hide the install error.
            if let failure {
                lastError = failure
                banners?.surfaceError("mcp", failure)
            }
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError("mcp", error.localizedDescription)
        }
    }

    /// Polls a detached install action until it stops running and returns its
    /// terminal status (nil if it never settled within the cap). Capped so a
    /// wedged action can't spin forever (the user can retry / refresh manually);
    /// transient status errors are tolerated within the cap.
    private func waitForBackgroundInstall(action: String) async -> DashboardActionStatus? {
        for _ in 0..<150 {
            if let status = try? await client.mcpActionStatus(action: action), !status.running {
                return status
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    private func envDict(from pairs: [KeyValuePair]) -> [String: String] {
        var dict: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            let value = pair.value
            // Drop blank keys and unfilled (still-redacted-placeholder) values so
            // an edit doesn't write a masked secret back over the real one.
            guard !key.isEmpty, !value.isEmpty else { continue }
            dict[key] = value
        }
        return dict
    }
}

// MARK: - View

struct MCPServersView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: an MCP-server `EntityLink` selects its row when this tab
    /// lands. Optional so the view renders without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: MCPServersHarness?

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                DashboardNotReadyView(systemImage: "server.rack")
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("MCP Servers")
        .dismissesBanner("mcp", from: banners)
        // Keyed on client availability so the harness is built when the dashboard
        // finishes booting and `client` flips non-nil (matching Cron/Environment).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { consumeFocus(harness: harness!); return }
            let h = MCPServersHarness(client: client)
            h.banners = banners
            harness = h
            await h.refresh()
            consumeFocus(harness: h)
        }
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
    }

    /// Selects the row named by a pending MCP-server focus, then clears it.
    /// Ignores focus aimed at another tab/page.
    private func consumeFocus(harness: MCPServersHarness) {
        guard let ref = navigator?.pendingFocus, case let .mcpServer(name) = ref else { return }
        if let match = harness.servers.first(where: { $0.name == name }) {
            harness.selectionID = match.id
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: MCPServersHarness) -> some View {
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.draft != nil || harness.selectedServer != nil || harness.showCatalog },
                set: { if !$0 { harness.closeSecondary() } }
            ),
            secondaryTitle: editorTitle(harness)
        ) {
            serversTable(harness: harness)
                .frame(minWidth: Idiom.isPhone ? nil : 280, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            editorPane(harness: harness)
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        // Hard errors route to the top-of-window strip; only the capability warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresMCPAPI,
                feature: "MCP servers via Hermes dashboard",
                // `hermesVersion` is the window's `effectiveHermesVersion` — the
                // live dashboard status version when known (see ServerWindowHarness).
                version: hermesVersion
            ),
            severity: .warning
        )
    }

    @ViewBuilder
    private func serversTable(harness: MCPServersHarness) -> some View {
        Table(harness.servers, selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            TableColumn("Name") { server in
                Text(server.name)
            }
            TableColumn("Transport") { server in
                Text(server.transport ?? "—")
                    .foregroundStyle(.secondary)
            }
            TableColumn("Address") { server in
                Text(server.url ?? server.command ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TableColumn("Enabled") { server in
                Toggle("", isOn: Binding(
                    get: { server.enabled },
                    set: { newValue in Task { await harness.setEnabled(server, enabled: newValue) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(harness.testing.contains(server.name))
            }
            .width(80)
        }
        .overlay {
            if harness.servers.isEmpty, !harness.isLoading {
                ContentUnavailableView("No MCP servers", systemImage: "server.rack")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: MCPServersHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Refresh the MCP servers")

            Button { harness.beginAdd() } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(harness.draft != nil)
            .help("Add an MCP server")

            Button {
                harness.showCatalog.toggle()
                if harness.showCatalog {
                    harness.draft = nil
                    Task { await harness.loadCatalog() }
                }
            } label: {
                Label("Catalog", systemImage: "square.grid.2x2")
            }
            .help("Browse the Nous-approved MCP catalog")

            Button {
                guard let server = harness.selectedServer else { return }
                Task { await harness.test(server) }
            } label: {
                Label("Test", systemImage: "bolt")
            }
            .disabled(harness.selectionID == nil)
            .help("Test the selected server's connection")

            Button {
                guard let server = harness.selectedServer else { return }
                Task { await harness.delete(server) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(harness.selectionID == nil)
            .help("Delete the selected MCP server")
        }
    }

    /// Title for the pushed iPhone secondary page — the draft editor, the
    /// catalog, or the selected server's name. nil when nothing opens it.
    private func editorTitle(_ harness: MCPServersHarness) -> String? {
        if harness.draft != nil { return harness.editingServer != nil ? "Edit MCP server" : "New MCP server" }
        if harness.showCatalog { return "MCP Catalog" }
        return harness.selectedServer?.name
    }

    @ViewBuilder
    private func editorPane(harness: MCPServersHarness) -> some View {
        if harness.draft != nil {
            DraftMCPServerEditor(
                draft: Binding(
                    get: { harness.draft ?? MCPServerDraft() },
                    set: { harness.draft = $0 }
                ),
                isEditing: harness.editingServer != nil,
                hasToolAllowlist: harness.editingServer?.tools?.isEmpty == false,
                onSave: { draft in Task { await harness.commit(draft) } },
                onCancel: { harness.cancelAdd() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if harness.showCatalog {
            MCPCatalogView(
                entries: harness.catalog,
                isLoading: harness.catalogLoading,
                installing: harness.installing,
                onInstall: { entry, env in Task { await harness.install(entry: entry, env: env) } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let server = harness.selectedServer {
            MCPServerDetail(
                server: server,
                testResult: harness.testResultName == server.name ? harness.testResult : nil,
                onEdit: { harness.beginEdit(server) }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Draft editor

private struct DraftMCPServerEditor: View {
    @Binding var draft: MCPServerDraft
    let isEditing: Bool
    /// True when re-creating a server that carries a tool-selection allowlist —
    /// the dashboard can't restore it on re-add, so the editor warns.
    var hasToolAllowlist: Bool = false
    let onSave: (MCPServerDraft) -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch draft.transport {
        case .stdio: return !draft.command.trimmingCharacters(in: .whitespaces).isEmpty
        case .http: return !draft.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Picker("Transport", selection: $draft.transport) {
                    Text("stdio (local command)").tag(MCPTransport.stdio)
                    Text("Remote (HTTP/SSE)").tag(MCPTransport.http)
                }
                if hasToolAllowlist {
                    Text("This server has a tool allowlist that re-creating won't preserve — it resets to all tools. Re-apply it with `hermes mcp` afterward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch draft.transport {
            case .stdio:
                Section("Command") {
                    TextField("Command (e.g. npx)", text: $draft.command)
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    TextField("Arguments (one per line)", text: $draft.argsText, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...4)
                }
                Section("Environment") {
                    KeyValueListEditor(pairs: $draft.env, valueIsSecret: true)
                    if isEditing {
                        Text("Secret values are hidden — re-enter a value to keep that variable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .http:
                Section("Endpoint") {
                    TextField("URL (https://…)", text: $draft.url)
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    Picker("Auth", selection: $draft.auth) {
                        Text("None").tag("")
                        Text("OAuth").tag("oauth")
                        Text("Header").tag("header")
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(isEditing ? "Save" : "Add") { onSave(draft) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSave)
            }
        }
    }
}

/// Reusable add/remove list of `KEY=VALUE` rows. Used for the stdio env block;
/// the value field masks as a secret when `valueIsSecret`.
private struct KeyValueListEditor: View {
    @Binding var pairs: [KeyValuePair]
    var valueIsSecret: Bool = false

    var body: some View {
        ForEach($pairs) { $pair in
            HStack(spacing: 6) {
                TextField("KEY", text: $pair.key)
                    .font(.system(.caption, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if valueIsSecret {
                    SecureField("value", text: $pair.value)
                        .font(.system(.caption, design: .monospaced))
                } else {
                    TextField("value", text: $pair.value)
                        .font(.system(.caption, design: .monospaced))
                }
                Button {
                    pairs.removeAll { $0.id == pair.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove variable")
                .help("Remove this variable")
            }
        }
        Button {
            pairs.append(KeyValuePair())
        } label: {
            Label("Add variable", systemImage: "plus")
        }
        .help("Add an environment variable")
    }
}

// MARK: - Detail

private struct MCPServerDetail: View {
    let server: DashboardMCPServer
    let testResult: DashboardMCPTestResult?
    let onEdit: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") { Text(server.name) }
                LabeledContent("Transport") { Text(server.transport ?? "—") }
                if let url = server.url {
                    LabeledContent("URL") {
                        Text(url).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let command = server.command {
                    LabeledContent("Command") {
                        Text(command).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let args = server.args, !args.isEmpty {
                    LabeledContent("Arguments") {
                        Text(args.joined(separator: " "))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                if let auth = server.auth {
                    LabeledContent("Auth") { Text(auth) }
                }
                LabeledContent("Enabled") { Text(server.enabled ? "Yes" : "No") }
            }

            if let env = server.env, !env.isEmpty {
                Section("Environment") {
                    ForEach(env.keys.sorted(), id: \.self) { key in
                        LabeledContent(key) {
                            Text(env[key] ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let testResult {
                Section(testResult.ok ? "Tools" : "Test failed") {
                    if let error = testResult.error, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if testResult.tools.isEmpty, testResult.ok {
                        Text("No tools reported.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(testResult.tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.system(.body, design: .monospaced))
                            if let description = tool.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button { onEdit() } label: {
                    Label("Edit (re-create)", systemImage: "pencil")
                }
                .help("Edit this server by re-creating it (delete + re-add)")
            }
        }
        .id(server.id)
    }
}

// MARK: - Catalog

private struct MCPCatalogView: View {
    let entries: [DashboardMCPCatalogEntry]
    let isLoading: Bool
    let installing: Set<String>
    let onInstall: (DashboardMCPCatalogEntry, [String: String]) -> Void

    var body: some View {
        List {
            Section {
                if entries.isEmpty {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("No catalog entries.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(entries) { entry in
                    MCPCatalogRow(
                        entry: entry,
                        installing: installing.contains(entry.name),
                        onInstall: { env in onInstall(entry, env) }
                    )
                }
            }
        }
    }
}

private struct MCPCatalogRow: View {
    let entry: DashboardMCPCatalogEntry
    let installing: Bool
    let onInstall: ([String: String]) -> Void

    /// Filled-in required env values, keyed by var name.
    @State private var envValues: [String: String] = [:]

    private var requiredEnv: [DashboardMCPRequiredEnv] { entry.requiredEnv ?? [] }

    private var missingRequired: Bool {
        requiredEnv.contains { ($0.required ?? false) && (envValues[$0.name] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.name).font(.headline)
                if let transport = entry.transport {
                    Text(transport)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if entry.installed == true {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            if let description = entry.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(requiredEnv) { variable in
                VStack(alignment: .leading, spacing: 2) {
                    Text(variable.prompt ?? variable.name)
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField(variable.name, text: Binding(
                        get: { envValues[variable.name] ?? "" },
                        set: { envValues[variable.name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                }
            }

            HStack {
                Spacer()
                if installing {
                    ProgressView().controlSize(.small)
                }
                Button(entry.installed == true ? "Reinstall" : "Install") {
                    onInstall(envValues.filter { !$0.value.isEmpty })
                }
                .disabled(installing || missingRequired)
                .help("Install this MCP server from the catalog")
            }
        }
        .padding(.vertical, 4)
    }
}
