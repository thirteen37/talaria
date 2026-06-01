import HermesKit
import SwiftUI

/// Which slot a model pick targets. `main` writes the main model;
/// `auxiliary(task:)` overrides one auxiliary slot.
enum ModelPickerTarget: Equatable {
    case main
    case auxiliary(task: String)
}

@MainActor
@Observable
final class ModelsHarness {
    var options: DashboardModelOptions?
    var assignments: DashboardModelAssignments?
    var isLoading: Bool = false
    var lastError: String?
    /// Non-nil while the provider/model picker pane is open.
    var pickerTarget: ModelPickerTarget?
    /// Slots with a write in flight, so their controls disable without
    /// blocking the whole screen.
    var busyTasks: Set<String> = []
    var mainBusy: Bool = false
    /// A bulk "reset all auxiliary" write is in flight. Tracked separately from
    /// `mainBusy` so it gates the reset action (not the unrelated main "Change"
    /// button) and blocks a second `__reset__` before the first completes.
    var bulkBusy: Bool = false
    /// User-defined OpenAI-compatible endpoints from `config.yaml`'s `providers`
    /// dict. Best-effort: a config fetch failure leaves the picker working.
    var customEndpoints: [CustomEndpoint] = []
    /// Endpoint slugs with a save/remove write in flight, so a single row's
    /// controls disable without blocking the rest of the screen.
    var endpointBusy: Set<String> = []

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    /// Auxiliary slots in Hermes' canonical order (the API already returns them
    /// ordered, but re-sort defensively so a reordering upstream can't scramble
    /// the UI). Unknown slots all share `rank == canonicalOrder.count`, so we
    /// tiebreak on `task` to keep their order stable across refreshes —
    /// `sorted(by:)` isn't guaranteed stable.
    var orderedTasks: [DashboardAuxiliaryModel] {
        (assignments?.tasks ?? []).sorted {
            let lhs = AuxiliaryModelSlot.rank(of: $0.task)
            let rhs = AuxiliaryModelSlot.rank(of: $1.task)
            return lhs == rhs ? $0.task < $1.task : lhs < rhs
        }
    }

    /// Providers the host has authenticated, exposed by `/api/model/options`.
    var authenticatedProviders: [DashboardModelProvider] {
        options?.providers ?? []
    }

    /// Known providers the host has *not* authenticated — shown disabled in the
    /// picker with a hint to run `hermes model`.
    var unauthenticatedProviders: [KnownModelProvider] {
        let authed = Set(authenticatedProviders.map(\.slug))
        return KnownModelProviders.unauthenticated(authenticatedSlugs: authed)
    }

    /// Loads options + assignments concurrently. Dashboard-only — `hermes model`
    /// is an interactive TTY wizard, so there's no CLI fallback.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        async let optionsTask = client.getModelOptions()
        async let assignmentsTask = client.getModelAssignments()
        async let configTask = client.getConfig()

        var firstError: String?
        do {
            options = try await optionsTask
        } catch {
            firstError = error.localizedDescription
        }
        do {
            assignments = try await assignmentsTask
        } catch {
            firstError = firstError ?? error.localizedDescription
        }
        // Config powers the custom-endpoints section. Tolerate its failure
        // without blocking the picker — an older/transient dashboard still
        // serves options + assignments, and the previous endpoint list stays.
        if let config = try? await configTask {
            customEndpoints = CustomEndpoint.list(in: config)
        }
        lastError = firstError
    }

    // MARK: - Picker lifecycle

    func beginPick(_ target: ModelPickerTarget) { pickerTarget = target }
    func cancelPick() { pickerTarget = nil }

    /// The provider+model currently assigned to the active picker target, so
    /// the picker can mark exactly that row `current`. Both halves matter: the
    /// same model id can appear under multiple providers (e.g. `gpt-4o` under
    /// both `openai` and `openrouter`), so matching on the id alone would badge
    /// every provider that lists it.
    func currentSelection(for target: ModelPickerTarget) -> (provider: String, model: String)? {
        switch target {
        case .main:
            guard let model = assignments?.main.model, !model.isEmpty else { return nil }
            return (assignments?.main.provider ?? "", model)
        case let .auxiliary(task):
            let slot = assignments?.tasks.first { $0.task == task }
            guard let slot, !slot.isAuto, let model = slot.model, !model.isEmpty else { return nil }
            return (slot.provider ?? "", model)
        }
    }

    /// Whether a `setModel` write for `target` is currently in flight, so the
    /// picker can disable its selectable rows and avoid a duplicate POST on a
    /// second tap before the round-trip + refresh completes (matters on a slow
    /// SSH-tunneled dashboard).
    func isWriting(for target: ModelPickerTarget) -> Bool {
        switch target {
        case .main: return mainBusy
        case let .auxiliary(task): return busyTasks.contains(task)
        }
    }

    // MARK: - Mutations

    /// Assigns the picked provider/model to the active target, then refreshes.
    func selectModel(provider: String, model: String) async {
        guard let target = pickerTarget else { return }
        await write(target: target) {
            switch target {
            case .main:
                try await $0.setModel(scope: .main, provider: provider, model: model)
            case let .auxiliary(task):
                try await $0.setModel(scope: .auxiliary, task: task, provider: provider, model: model)
            }
        }
    }

    /// Resets a single auxiliary slot back to auto (provider `"auto"`, empty
    /// model). The set route writes those values verbatim, which is exactly
    /// "inherit the main model".
    func resetAuxiliary(task: String) async {
        await write(target: .auxiliary(task: task)) {
            try await $0.setModel(scope: .auxiliary, task: task, provider: "auto", model: "")
        }
    }

    /// Resets every auxiliary slot to auto via the `__reset__` sentinel.
    func resetAllAuxiliary() async {
        await write(target: nil) {
            try await $0.setModel(scope: .auxiliary, task: "__reset__", provider: "", model: "")
        }
    }

    // MARK: - Custom endpoints

    /// Saves an endpoint (add or edit). Config is fetched once up front; for a
    /// brand-new endpoint the stable slug is derived from *that* fresh config's
    /// provider keys (not the possibly-stale in-memory list) and the merge
    /// writes back into the same object — so a slug added by another window or a
    /// hand edit since the last refresh is both de-duped against and preserved.
    ///
    /// The `api_key` field is governed by what the user did: entering a new key
    /// stores the secret in `.env` and writes the derived `${VAR}` reference
    /// (`.set`); leaving the field blank on a keyed endpoint keeps the existing
    /// reference verbatim (`.keep`) so a non-derived `${MY_VAR}`/literal isn't
    /// repointed at an unset derived var; otherwise no key is written
    /// (`.remove`).
    /// Returns whether the save completed, so the form can keep the sheet (and
    /// the typed key) open on failure rather than dismissing and losing input.
    @discardableResult
    func saveEndpoint(_ endpoint: CustomEndpoint, newKey: String?) async -> Bool {
        let fresh: JSONValue
        do {
            fresh = try await client.getConfig()
        } catch {
            lastError = error.localizedDescription
            return false
        }

        // A new endpoint (empty slug) lands in the `providers:` dict under a slug
        // de-duped against the *fresh* config. An edit keeps its slug and source,
        // so the write targets wherever the entry actually lives.
        let draft: CustomEndpoint
        if endpoint.slug.isEmpty {
            // Reject an exact (name, base_url, model) duplicate up front. The new
            // entry would be written to `providers.<slug>` but `list(in:)`'s
            // list-wins dedup would hide it behind the matching `custom_providers`
            // entry on the next refresh — so the save would look successful yet
            // nothing new would appear. A clear error beats that silent no-op.
            if CustomEndpoint.list(in: fresh).contains(where: {
                $0.name == endpoint.name
                    && $0.baseURL == endpoint.baseURL
                    && $0.defaultModel == endpoint.defaultModel
            }) {
                lastError = "An endpoint named “\(endpoint.name)” with that base URL already exists."
                return false
            }
            // De-dup the slug against the displayed slugs *and* the raw `providers`
            // keys. The raw keys matter because `list(in:)` hides a
            // `providers.<slug>` entry that duplicates a `custom_providers` list
            // entry — without them a new endpoint could slugify onto that hidden
            // key and `upsert` would overwrite it, losing its api_key/settings.
            var taken = CustomEndpoint.list(in: fresh).map(\.slug)
            if case let .object(root) = fresh, case let .object(providers) = root["providers"] {
                taken.append(contentsOf: providers.keys)
            }
            let slug = CustomEndpoint.slug(forName: endpoint.name, existing: taken)
            draft = CustomEndpoint(
                slug: slug,
                name: endpoint.name,
                baseURL: endpoint.baseURL,
                models: endpoint.models,
                defaultModel: endpoint.defaultModel,
                discoverModels: endpoint.discoverModels,
                hasAPIKey: endpoint.hasAPIKey,
                source: .providersDict(slug: slug)
            )
        } else {
            draft = endpoint
        }

        // For a list edit, confirm the target still exists in the fresh config
        // *before* mutating anything. If it was removed elsewhere since the last
        // refresh, `upsertListEntry` would re-resolve to nothing and no-op — but
        // the sheet would still report success while a just-written key var was
        // left orphaned. Failing up front keeps the sheet open with a real error
        // and writes nothing. `oldKeyEnv` captures the entry's current key var so
        // a rename (which moves the derived var name) can clean up the stale one.
        var oldKeyEnv: String?
        if case let .customProvidersList(anchor) = draft.source {
            guard let entry = CustomEndpoint.listEntry(for: anchor, in: fresh) else {
                lastError = "This endpoint no longer exists — it may have been removed in another window. Reopen the list and try again."
                return false
            }
            oldKeyEnv = Self.listEntryKeyEnv(entry)
        }

        let action: CustomEndpoint.APIKeyWrite =
            (newKey?.isEmpty == false) ? .set : (draft.hasAPIKey ? .keep : .remove)
        let newVarName = CustomEndpoint.apiKeyEnvVarName(forSlug: draft.slug)

        return await runEndpoint(slug: draft.slug) {
            if let newKey, !newKey.isEmpty {
                try await $0.setEnvVar(key: newVarName, value: newKey)
            }
            let updated: JSONValue
            switch draft.source {
            case .providersDict:
                updated = CustomEndpoint.upsert(draft, apiKey: action, in: fresh)
            case let .customProvidersList(anchor):
                updated = CustomEndpoint.upsertListEntry(draft, apiKey: action, anchor: anchor, in: fresh)
            }
            try await $0.updateConfig(updated)
            // Renaming a list entry moves its derived var name; delete the stale
            // app-managed one so a rekey-on-rename doesn't orphan a secret (the
            // dict path never orphans, its slug being stable). Best-effort, and
            // never a user's own/shared var.
            if action == .set,
               let oldVar = oldKeyEnv,
               oldVar != newVarName,
               Self.isAppManagedAPIKeyVar(oldVar) {
                try? await $0.deleteEnvVar(key: oldVar)
            }
        }
    }

    /// Removes an endpoint from wherever it lives — `providers.<slug>` (dict) or
    /// its `custom_providers` element (list, re-resolved by content) — then
    /// cleans up its `.env` key var: the slug-derived name for a dict entry, or
    /// the var the list entry actually references (only when app-managed). The
    /// env deletion is best-effort cleanup of a key the config no longer
    /// references, so any failure there (not just the 404 the client already
    /// tolerates) is swallowed — the config removal is the meaningful action and
    /// must drive the success/refresh path rather than stranding the removed
    /// endpoint in the list. A leftover `.env` line is
    /// harmless; the user can retry remove to re-attempt cleanup.
    func removeEndpoint(_ endpoint: CustomEndpoint) async {
        await runEndpoint(slug: endpoint.slug) {
            let fresh = try await $0.getConfig()
            let updated: JSONValue
            // The `.env` var to clean up. For a dict entry it's the slug-derived
            // name (the slug is the stable on-disk key). For a list entry the
            // slug is synthesized from the mutable name and drifts on rename, so
            // read the var the entry actually references — but only delete it
            // when it's an app-managed `HERMES_CUSTOM_*_API_KEY`, never a user's
            // own/shared var that a `key_env`/`api_key_env` might point at.
            let envVarToDelete: String?
            switch endpoint.source {
            case let .providersDict(slug):
                updated = CustomEndpoint.remove(slug: slug, from: fresh)
                envVarToDelete = CustomEndpoint.apiKeyEnvVarName(forSlug: slug)
            case let .customProvidersList(anchor):
                updated = CustomEndpoint.removeListEntry(anchor: anchor, from: fresh)
                let referenced = CustomEndpoint.listEntry(for: anchor, in: fresh)
                    .flatMap(Self.listEntryKeyEnv)
                envVarToDelete = referenced.flatMap { Self.isAppManagedAPIKeyVar($0) ? $0 : nil }
            }
            try await $0.updateConfig(updated)
            if let envVarToDelete {
                try? await $0.deleteEnvVar(key: envVarToDelete)
            }
        }
    }

    /// Reveals an endpoint's stored key on demand.
    ///
    /// For a **dict** endpoint the var name is the slug-derived one (the slug is
    /// the stable on-disk key); a 404 (key stored under a non-derived name, e.g.
    /// hand-edited config) falls back to the literal `api_key`.
    ///
    /// For a **list** endpoint the slug is synthesized from the mutable name and
    /// drifts on rename, so the slug-derived name would miss after a rename. Read
    /// the var the entry actually references (`key_env`/`api_key_env`) and reveal
    /// *that*; a 404 (var unset) falls back to the literal `api_key` (which
    /// `hermes model` stores), as does an entry with no var reference at all.
    ///
    /// nil means "no key to reveal" (missing, or only an unresolved `${VAR}`).
    /// Any other failure (network, 5xx, unauthorized, rate-limit) is rethrown so
    /// the caller shows a real error rather than an empty field that looks like a
    /// cleared key.
    func revealEndpointKey(for endpoint: CustomEndpoint) async throws -> String? {
        switch endpoint.source {
        case let .providersDict(slug):
            do {
                return try await client.revealEnvVar(key: CustomEndpoint.apiKeyEnvVarName(forSlug: slug))
            } catch let DashboardClientError.http(statusCode, _) where statusCode == 404 {
                return try await expandedConfigKey(for: endpoint)
            }
        case let .customProvidersList(anchor):
            let config = try await client.getConfig()
            guard let entry = CustomEndpoint.listEntry(for: anchor, in: config) else { return nil }
            guard let varName = Self.listEntryKeyEnv(entry) else {
                return Self.literalConfigKey(entry)
            }
            do {
                return try await client.revealEnvVar(key: varName)
            } catch let DashboardClientError.http(statusCode, _) where statusCode == 404 {
                return Self.literalConfigKey(entry)
            }
        }
    }

    /// The endpoint's literal `api_key` from a fresh config — read from wherever
    /// the entry lives (`providers.<slug>` or its `custom_providers` element).
    /// Nil when it's missing or only an unresolved `${VAR}` template.
    private func expandedConfigKey(for endpoint: CustomEndpoint) async throws -> String? {
        let config = try await client.getConfig()
        guard case let .object(root) = config else { return nil }
        switch endpoint.source {
        case let .providersDict(slug):
            guard case let .object(providers) = root["providers"],
                  case let .object(entry) = providers[slug] else { return nil }
            return Self.literalConfigKey(entry)
        case let .customProvidersList(anchor):
            guard let entry = CustomEndpoint.listEntry(for: anchor, in: config) else { return nil }
            return Self.literalConfigKey(entry)
        }
    }

    /// The env var a `custom_providers` entry references for its key, if any —
    /// the app-managed `key_env` or a user's `api_key_env` alias.
    private static func listEntryKeyEnv(_ entry: [String: JSONValue]) -> String? {
        if case let .string(value) = entry["key_env"], !value.isEmpty { return value }
        if case let .string(value) = entry["api_key_env"], !value.isEmpty { return value }
        return nil
    }

    /// A config entry's literal `api_key`, or nil when absent or an unresolved
    /// `${VAR}` template (the referenced var is unset, so there's nothing to show).
    private static func literalConfigKey(_ entry: [String: JSONValue]) -> String? {
        guard case let .string(apiKey) = entry["api_key"],
              !apiKey.isEmpty,
              !(apiKey.hasPrefix("${") && apiKey.hasSuffix("}")) else {
            return nil
        }
        return apiKey
    }

    /// Whether `name` is one of Talaria's derived `HERMES_CUSTOM_<…>_API_KEY`
    /// vars — so removal only cleans up keys the app created, never a user's
    /// own/shared var a `key_env`/`api_key_env` might point at.
    private static func isAppManagedAPIKeyVar(_ name: String) -> Bool {
        name.hasPrefix("HERMES_CUSTOM_") && name.hasSuffix("_API_KEY")
    }

    /// Whether a save/remove is in flight for `slug`, so its row's controls
    /// disable without freezing the rest of the screen.
    func isEndpointBusy(slug: String) -> Bool { endpointBusy.contains(slug) }

    @discardableResult
    private func runEndpoint(slug: String, _ body: (DashboardClient) async throws -> Void) async -> Bool {
        endpointBusy.insert(slug)
        defer { endpointBusy.remove(slug) }
        do {
            try await body(client)
            lastError = nil
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Shared write wrapper: marks the target busy, runs the dashboard call,
    /// surfaces any error, closes the picker, and refreshes on success.
    private func write(target: ModelPickerTarget?, _ body: (DashboardClient) async throws -> Void) async {
        setBusy(target, true)
        defer { setBusy(target, false) }
        do {
            try await body(client)
            lastError = nil
            pickerTarget = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func setBusy(_ target: ModelPickerTarget?, _ value: Bool) {
        switch target {
        case .main:
            mainBusy = value
        case let .auxiliary(task):
            if value { busyTasks.insert(task) } else { busyTasks.remove(task) }
        case nil:
            bulkBusy = value
        }
    }
}

struct ModelsView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @State private var harness: ModelsHarness?
    /// Drives the confirm dialog for the destructive "Reset auxiliary" action —
    /// an unlabeled toolbar button sitting next to Refresh, so a mis-click
    /// shouldn't silently wipe every per-slot override.
    @State private var showResetConfirm: Bool = false
    /// Add/edit sheet for a custom endpoint (nil = closed).
    @State private var endpointSheet: EndpointSheet?
    /// Endpoint queued for removal, awaiting confirmation.
    @State private var endpointToRemove: CustomEndpoint?

    /// Identifies the endpoint sheet so `.sheet(item:)` rebuilds when switching
    /// between Add and a specific endpoint's Edit.
    private enum EndpointSheet: Identifiable {
        case add
        case edit(CustomEndpoint)

        var id: String {
            switch self {
            case .add: return "__add__"
            case let .edit(endpoint): return endpoint.slug
            }
        }
    }

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "cpu",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Models")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil (matching the
        // other dashboard surfaces).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = ModelsHarness(client: client)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: ModelsHarness) -> some View {
        PlatformSplit(showsSecondary: harness.pickerTarget != nil) {
            assignmentsForm(harness: harness)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            pickerPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        .manageBanner(
            harness.lastError ?? capabilityBanner(
                .requiresModelAPI,
                feature: "Model management via Hermes dashboard",
                version: hermesVersion
            ),
            severity: harness.lastError != nil ? .error : .warning
        )
        .alert("Reset all auxiliary models?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) {
                Task { await harness.resetAllAuxiliary() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every auxiliary slot returns to “auto”, reusing your main model. Per-slot overrides are lost. This cannot be undone.")
        }
        .sheet(item: $endpointSheet) { sheet in
            switch sheet {
            case .add:
                CustomEndpointForm(harness: harness, existing: nil)
            case let .edit(endpoint):
                CustomEndpointForm(harness: harness, existing: endpoint)
            }
        }
        .confirmationDialog(
            "Remove “\(endpointToRemove?.name ?? "")”?",
            isPresented: Binding(
                get: { endpointToRemove != nil },
                set: { if !$0 { endpointToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let endpoint = endpointToRemove {
                    Task { await harness.removeEndpoint(endpoint) }
                }
                endpointToRemove = nil
            }
            Button("Cancel", role: .cancel) { endpointToRemove = nil }
        } message: {
            Text("The endpoint and its stored API key are deleted. Any model slot still assigned to it will no longer resolve. This cannot be undone.")
        }
    }

    // MARK: - Assignments form

    @ViewBuilder
    private func assignmentsForm(harness: ModelsHarness) -> some View {
        Form {
            Section("Main model") {
                mainRow(harness: harness)
            }

            Section {
                ForEach(harness.orderedTasks) { slot in
                    auxiliaryRow(harness: harness, slot: slot)
                }
                if harness.orderedTasks.isEmpty, !harness.isLoading {
                    Text("No auxiliary slots reported.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Auxiliary models")
            } footer: {
                Text("Auxiliary slots default to “auto”, reusing your main model. Override a slot to use a cheaper or faster model for that side-job.")
            }

            Section {
                ForEach(harness.customEndpoints) { endpoint in
                    endpointRow(harness: harness, endpoint: endpoint)
                }
                if harness.customEndpoints.isEmpty, !harness.isLoading {
                    Text("No custom endpoints yet.")
                        .foregroundStyle(.secondary)
                }
                Button {
                    endpointSheet = .add
                } label: {
                    Label("Add endpoint", systemImage: "plus")
                }
                .help("Add a custom OpenAI-compatible endpoint")
            } header: {
                Text("Custom endpoints")
            } footer: {
                Text("OpenAI-compatible endpoints become selectable providers above. API keys are stored in ~/.hermes/.env and referenced from config.yaml — never written there in plaintext.")
            }
        }
        .formStyle(.grouped)
        .overlay {
            if harness.assignments == nil, harness.isLoading {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func mainRow(harness: ModelsHarness) -> some View {
        let main = harness.assignments?.main
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mainDisplay(main))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let provider = main?.provider, !provider.isEmpty {
                    Text(provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Change") { harness.beginPick(.main) }
                .disabled(harness.mainBusy)
                .help("Choose the main model")
        }
    }

    @ViewBuilder
    private func auxiliaryRow(harness: ModelsHarness, slot: DashboardAuxiliaryModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AuxiliaryModelSlot.label(for: slot.task))
                Text(auxiliaryDisplay(slot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Change") { harness.beginPick(.auxiliary(task: slot.task)) }
                .disabled(harness.busyTasks.contains(slot.task))
                .help("Choose the model for \(AuxiliaryModelSlot.label(for: slot.task))")
            Button("Reset") { Task { await harness.resetAuxiliary(task: slot.task) } }
                .disabled(slot.isAuto || harness.busyTasks.contains(slot.task))
                .help("Reset \(AuxiliaryModelSlot.label(for: slot.task)) to auto (use the main model)")
        }
    }

    private func mainDisplay(_ main: DashboardMainModel?) -> String {
        guard let model = main?.model, !model.isEmpty else { return "Not set" }
        return model
    }

    private func auxiliaryDisplay(_ slot: DashboardAuxiliaryModel) -> String {
        if slot.isAuto { return "auto (use main model)" }
        let model = slot.model ?? ""
        let provider = slot.provider ?? ""
        if model.isEmpty { return provider.isEmpty ? "auto (use main model)" : provider }
        return provider.isEmpty ? model : "\(provider) · \(model)"
    }

    // MARK: - Custom endpoint rows

    @ViewBuilder
    private func endpointRow(harness: ModelsHarness, endpoint: CustomEndpoint) -> some View {
        let busy = harness.isEndpointBusy(slug: endpoint.slug)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(endpointSubtitle(endpoint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if endpoint.hasAPIKey {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("API key configured")
                    .help("An API key is configured for this endpoint")
            }
            Button("Edit") { endpointSheet = .edit(endpoint) }
                .disabled(busy)
                .help("Edit “\(endpoint.name)”")
            Button("Remove") { endpointToRemove = endpoint }
                .disabled(busy)
                .help("Remove “\(endpoint.name)” and its stored API key")
        }
    }

    private func endpointSubtitle(_ endpoint: CustomEndpoint) -> String {
        let models = endpoint.discoverModels
            ? "auto-detect"
            : "\(endpoint.models.count) model\(endpoint.models.count == 1 ? "" : "s")"
        return endpoint.baseURL.isEmpty ? models : "\(endpoint.baseURL) · \(models)"
    }

    // MARK: - Picker pane

    // Rendered only while `pickerTarget != nil` — `PlatformSplit`'s
    // `showsSecondary` gate hides this pane otherwise.
    @ViewBuilder
    private func pickerPane(harness: ModelsHarness) -> some View {
        if let target = harness.pickerTarget {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(pickerTitle(target))
                        .font(.headline)
                    Spacer()
                    Button("Cancel") { harness.cancelPick() }
                        .help("Close the model picker")
                }
                .padding(12)
                Divider()
                pickerList(harness: harness, target: target)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private func pickerList(harness: ModelsHarness, target: ModelPickerTarget) -> some View {
        if harness.authenticatedProviders.isEmpty {
            ContentUnavailableView {
                Label("No authenticated providers", systemImage: "key.slash")
            } description: {
                Text("Run `hermes model` in a terminal on the server to add a provider and authenticate.")
            }
        } else {
            let current = harness.currentSelection(for: target)
            Form {
                Section("Available") {
                    ForEach(harness.authenticatedProviders) { provider in
                        providerDisclosure(harness: harness, provider: provider, current: current)
                    }
                }
                if !harness.unauthenticatedProviders.isEmpty {
                    Section {
                        ForEach(harness.unauthenticatedProviders) { provider in
                            HStack {
                                Text(provider.label)
                                Spacer()
                                Image(systemName: "key.slash")
                            }
                            .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Not authenticated")
                    } footer: {
                        Text("Run `hermes model` in a terminal on the server to add one of these providers.")
                    }
                }
            }
            .formStyle(.grouped)
            // Block a duplicate POST from a second tap while the chosen model's
            // write is still round-tripping. Cancel lives in the pane header
            // (outside this Form), so it stays tappable.
            .disabled(harness.isWriting(for: target))
        }
    }

    @ViewBuilder
    private func providerDisclosure(
        harness: ModelsHarness,
        provider: DashboardModelProvider,
        current: (provider: String, model: String)?
    ) -> some View {
        DisclosureGroup {
            if provider.models.isEmpty {
                Text("No curated models — run `hermes model` to pick one manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(provider.models, id: \.self) { model in
                    Button {
                        Task { await harness.selectModel(provider: provider.slug, model: model) }
                    } label: {
                        HStack {
                            Text(model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if provider.slug == current?.provider, model == current?.model {
                                Text("current")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } label: {
            Text(provider.displayName)
        }
    }

    private func pickerTitle(_ target: ModelPickerTarget) -> String {
        switch target {
        case .main: return "Choose main model"
        case let .auxiliary(task): return "Choose \(AuxiliaryModelSlot.label(for: task)) model"
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(harness: ModelsHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                showResetConfirm = true
            } label: {
                Label("Reset auxiliary", systemImage: "arrow.uturn.backward")
            }
            .disabled(harness.isLoading || harness.bulkBusy || harness.assignments == nil)
            .help("Reset all auxiliary slots to auto (use the main model)")

            Button {
                Task { await harness.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload models and assignments")
        }
    }
}
