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
