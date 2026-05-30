import HermesKit
import SwiftUI

/// View-model for the single-profile config editor. Loads a profile's schema +
/// config from its dashboard, exposes a structured form and an editable YAML
/// mirror of the same edited state, and saves non-destructively. Comparison
/// state is additive — a compact (iPhone) variant can reuse this harness and
/// simply never set `comparing`.
///
/// The dashboard is reached only through injected `acquireScoped`/`releaseScoped`
/// closures (the window harness wires the macOS coordinator or the iOS
/// supervisor), so this type stays platform-neutral.
@MainActor
@Observable
final class ConfigEditorHarness {
    enum Mode: String, CaseIterable, Identifiable {
        case structured
        case yaml
        var id: String { rawValue }
        var label: String { self == .structured ? "Structured" : "YAML" }
    }

    // Profile selection
    var profiles: [HermesProfileInfo] = []
    var selectedProfile: String
    /// Set when `hermes profile list` is too old to exist; the editor still
    /// works against the single `default` profile.
    var profilesUnavailable = false

    // Single-profile editor state
    var mode: Mode = .structured
    private(set) var schema: DashboardConfigSchema?
    private(set) var form: ProfileConfigForm?
    /// Last GET — the non-destructive merge base and the dirty baseline.
    private(set) var original: JSONValue?
    /// Live edited config; structured controls mutate it, the YAML pane mirrors it.
    private(set) var working: JSONValue = .object([:])
    var yamlText: String = ""
    var yamlParseError: String?

    // Comparison (desktop only)
    var comparing = false
    var compareProfile: String = ""
    private(set) var comparison: ConfigComparison?
    var showDifferencesOnly = false

    // Status
    var isLoading = false
    var lastError: String?
    /// Dashboard client unavailable (not yet online, or spawn failed): the
    /// editor degrades to a read-only YAML view from the on-disk config and
    /// disables Save.
    var dashboardUnavailable = false

    // Dependencies
    private let defaultClientProvider: @MainActor () -> DashboardClient?
    private let runner: HermesAdminRunning?
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?
    private let acquireScoped: @MainActor (String) async throws -> (DashboardSupervisor, DashboardClient)
    private let releaseScoped: @MainActor (DashboardSupervisor) async -> Void

    // Held profile-scoped dashboard for a non-default selection.
    private var heldSupervisor: DashboardSupervisor?
    private var heldClient: DashboardClient?
    private var heldProfileName: String?

    // Serializes comparison reads so rapid selection changes don't fire
    // concurrent NIO-SSH reads that race host-key verification.
    private var compareTask: Task<Void, Never>?
    // Serializes config loads so rapid profile switches can't run overlapping
    // GETs (which would race `resolveClient`'s scoped-dashboard bookkeeping and
    // let a slow earlier response clobber a newer profile's state).
    private var loadTask: Task<Void, Never>?

    init(
        selectedProfile: String = HermesProfiles.defaultProfileName,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        runner: HermesAdminRunning?,
        profile: ServerProfile,
        transfer: RemoteSnapshotTransfer?,
        acquireScoped: @escaping @MainActor (String) async throws -> (DashboardSupervisor, DashboardClient),
        releaseScoped: @escaping @MainActor (DashboardSupervisor) async -> Void
    ) {
        self.selectedProfile = selectedProfile
        self.defaultClientProvider = defaultClient
        self.runner = runner
        self.serverProfile = profile
        self.transfer = transfer
        self.acquireScoped = acquireScoped
        self.releaseScoped = releaseScoped
    }

    var isDirty: Bool {
        guard let original, !dashboardUnavailable else { return false }
        return working != original
    }

    var canSave: Bool {
        isDirty && !isLoading && !dashboardUnavailable && yamlParseError == nil
    }

    // MARK: - Loading

    func start() async {
        await loadProfiles()
        load()
    }

    func refresh() async {
        await loadProfiles()
        load()
    }

    func loadProfiles() async {
        // Prefer the dashboard API: it returns clean names + a structured
        // is-default flag, where the CLI `hermes profile list` decorates the
        // default row with a marker glyph that leaks into the parsed name.
        if let client = defaultClientProvider() {
            do {
                let list = try await client.listProfiles()
                profiles = list.map { HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, status: nil) }
                profilesUnavailable = false
                normalizeSelections()
                return
            } catch {
                // Fall through to the CLI source (dashboard down / too old).
            }
        }
        guard let runner else {
            profiles = [HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true, status: nil)]
            normalizeSelections()
            return
        }
        do {
            profiles = try await HermesProfiles.list(runner: runner)
            profilesUnavailable = false
            normalizeSelections()
        } catch {
            handleProfilesError(error)
        }
    }

    /// Keeps the selected (and compare) profiles valid against the current list.
    private func normalizeSelections() {
        if !profiles.contains(where: { $0.name == selectedProfile }) {
            selectedProfile = profiles.first(where: \.isDefault)?.name
                ?? profiles.first?.name
                ?? HermesProfiles.defaultProfileName
        }
        if compareProfile.isEmpty || !profiles.contains(where: { $0.name == compareProfile }) {
            compareProfile = profiles.first(where: { $0.name != selectedProfile })?.name ?? ""
        }
    }

    /// Schedules a config load, chained behind any in-flight load so two never
    /// overlap. Fire-and-forget: the view observes the harness state as it lands.
    func load() {
        let previous = loadTask
        loadTask = Task { [weak self] in
            await previous?.value
            await self?.performLoad()
        }
    }

    private func performLoad() async {
        // Capture the profile this load is for. Each assignment after an `await`
        // bails if the selection moved on, so a slow earlier response can't
        // clobber a newer profile's state (mirrors `performCompare`).
        let target = selectedProfile
        isLoading = true
        defer { isLoading = false }
        let client = await resolveClient()
        guard selectedProfile == target else { return }
        if let client {
            do {
                async let schemaResult = client.getConfigSchema()
                async let configResult = client.getConfig()
                let schema = try await schemaResult
                let config = try await configResult
                guard selectedProfile == target else { return }
                self.schema = schema
                original = config
                working = config
                form = ProfileConfigForm.make(schema: schema, config: config)
                yamlText = (try? YAMLConfigCodec.yaml(from: config)) ?? ""
                yamlParseError = nil
                dashboardUnavailable = false
                lastError = nil
                if mode == .yaml { regenerateYAML() }
            } catch {
                guard selectedProfile == target else { return }
                lastError = error.localizedDescription
            }
        } else {
            await loadDegraded(target: target)
        }
        if comparing { scheduleCompare() }
    }

    /// Re-runs the load when the window's default dashboard comes online after
    /// an initial degraded render (the editor opened before the spawn finished).
    func reloadIfDashboardAppeared() {
        guard dashboardUnavailable,
              selectedProfile == HermesProfiles.defaultProfileName,
              defaultClientProvider() != nil else { return }
        load()
    }

    private func loadDegraded(target: String) async {
        guard selectedProfile == target else { return }
        dashboardUnavailable = true
        schema = nil
        form = nil
        original = nil
        // Best-effort: show the on-disk config read-only so the surface isn't
        // empty while the dashboard is unreachable.
        do {
            let text = try await HermesConfigReader.read(
                profile: serverProfile,
                profileName: target,
                transfer: transfer
            )
            guard selectedProfile == target else { return }
            yamlText = text
            mode = .yaml
        } catch {
            guard selectedProfile == target else { return }
            yamlText = ""
        }
    }

    private func resolveClient() async -> DashboardClient? {
        if selectedProfile == HermesProfiles.defaultProfileName {
            await releaseHeld()
            return defaultClientProvider()
        }
        if heldProfileName == selectedProfile, let heldClient {
            return heldClient
        }
        await releaseHeld()
        do {
            let (supervisor, client) = try await acquireScoped(selectedProfile)
            heldSupervisor = supervisor
            heldClient = client
            heldProfileName = selectedProfile
            return client
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func releaseHeld() async {
        if let heldSupervisor {
            await releaseScoped(heldSupervisor)
        }
        heldSupervisor = nil
        heldClient = nil
        heldProfileName = nil
    }

    /// Releases any profile-scoped dashboard this editor acquired. Call from the
    /// view's teardown.
    func teardown() async {
        await releaseHeld()
    }

    // MARK: - Profile / mode switching

    func selectProfile(_ name: String) async {
        guard name != selectedProfile else { return }
        selectedProfile = name
        if compareProfile == name {
            compareProfile = profiles.first(where: { $0.name != name })?.name ?? ""
        }
        load()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        switch newMode {
        case .yaml:
            regenerateYAML()
            yamlParseError = nil
            mode = .yaml
        case .structured:
            // Don't leave the user staring at a structured form built from
            // stale values while their YAML doesn't parse.
            guard yamlParseError == nil else { return }
            mode = .structured
        }
    }

    private func regenerateYAML() {
        yamlText = (try? YAMLConfigCodec.yaml(from: working)) ?? yamlText
    }

    /// Re-parses the YAML pane into `working` on each edit so the structured
    /// view and dirty/save state stay in sync. Parse failures surface inline and
    /// leave `working` at its last good value.
    func yamlChanged() {
        guard mode == .yaml, !dashboardUnavailable else { return }
        do {
            working = try YAMLConfigCodec.jsonValue(fromYAML: yamlText)
            yamlParseError = nil
        } catch {
            yamlParseError = error.localizedDescription
        }
    }

    // MARK: - Structured field access

    func value(for field: ConfigFormField) -> ConfigValue {
        guard let leaf = ProfileConfigForm.value(at: field.key, in: working) else { return .missing }
        return ProfileConfigForm.configValue(from: leaf, schemaType: field.schema?.type)
    }

    private func setWorking(_ key: String, _ json: JSONValue) {
        working = ProfileConfigForm.setValue(json, at: key, in: working)
    }

    func stringBinding(for field: ConfigFormField) -> Binding<String> {
        Binding(
            get: { [weak self] in self.map { Self.string(from: $0.value(for: field)) } ?? "" },
            set: { [weak self] in self?.setWorking(field.key, .string($0)) }
        )
    }

    func boolBinding(for field: ConfigFormField) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                if let self, case .bool(let b) = self.value(for: field) { return b }
                return false
            },
            set: { [weak self] in self?.setWorking(field.key, .bool($0)) }
        )
    }

    /// Text side of a number field (string bridge so partial input doesn't crash
    /// the control). Parseable text stores a JSON number; anything else stores a
    /// string the schema coercion resolves at save.
    func numberTextBinding(for field: ConfigFormField) -> Binding<String> {
        Binding(
            get: { [weak self] in self.map { Self.string(from: $0.value(for: field)) } ?? "" },
            set: { [weak self] text in
                if let number = Double(text) {
                    self?.setWorking(field.key, .number(number))
                } else {
                    self?.setWorking(field.key, .string(text))
                }
            }
        )
    }

    /// Stepper side of a number field.
    func numberBinding(for field: ConfigFormField) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                if let self, case .number(let n) = self.value(for: field) { return n }
                return 0
            },
            set: { [weak self] in self?.setWorking(field.key, .number($0)) }
        )
    }

    func listBinding(for field: ConfigFormField) -> Binding<[String]> {
        Binding(
            get: { [weak self] in
                if let self, case .list(let items) = self.value(for: field) { return items }
                return []
            },
            set: { [weak self] in self?.setWorking(field.key, .array($0.map(JSONValue.string))) }
        )
    }

    private static func string(from value: ConfigValue) -> String {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .list(let items): return items.joined(separator: ", ")
        case .missing: return ""
        case .raw: return ""
        }
    }

    // MARK: - Save

    func save() async {
        guard canSave else { return }
        isLoading = true
        defer { isLoading = false }
        guard let client = await resolveClient() else {
            lastError = "Dashboard is unavailable; can't save."
            return
        }
        do {
            let toPut: JSONValue
            if mode == .yaml {
                // The YAML pane owns the whole document, so PUT it as parsed
                // (this is where key removals take effect).
                toPut = try YAMLConfigCodec.jsonValue(fromYAML: yamlText)
            } else {
                guard let original else { return }
                // Re-GET immediately before PUT and merge only edited dotpaths so
                // a concurrent external change to another key isn't clobbered.
                let fresh = try await client.getConfig()
                let edits = ProfileConfigForm.edits(from: working, base: original, schema: schema)
                toPut = ProfileConfigForm.merged(into: fresh, edits: edits)
            }
            try await client.updateConfig(toPut)
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Comparison (desktop)

    func toggleComparing() {
        comparing.toggle()
        if comparing {
            if compareProfile.isEmpty {
                compareProfile = profiles.first(where: { $0.name != selectedProfile })?.name ?? ""
            }
            scheduleCompare()
        } else {
            comparison = nil
        }
    }

    func setCompareProfile(_ name: String) {
        compareProfile = name
        scheduleCompare()
    }

    /// Chains the next comparison behind the previous one so concurrent reads
    /// never overlap (the NIO transport opens a fresh SSH connection per read
    /// and racing two host-key verifications fails one side).
    private func scheduleCompare() {
        let previous = compareTask
        compareTask = Task { [weak self] in
            await previous?.value
            await self?.performCompare()
        }
    }

    private func performCompare() async {
        let source = selectedProfile
        let dest = compareProfile
        guard !dest.isEmpty, dest != source else {
            comparison = nil
            return
        }
        do {
            // Sequential reads: on the NIO transport concurrent reads race two
            // host-key verifications (mirrors ProfilesConfigHarness).
            let sourceText = try await HermesConfigReader.read(profile: serverProfile, profileName: source, transfer: transfer)
            let destText = try await HermesConfigReader.read(profile: serverProfile, profileName: dest, transfer: transfer)
            guard selectedProfile == source, compareProfile == dest else { return }
            let sourceDoc = try HermesConfigDocument.parse(sourceText)
            let destDoc = try HermesConfigDocument.parse(destText)
            comparison = ConfigComparison(source: sourceDoc, dest: destDoc)
            lastError = nil
        } catch {
            guard selectedProfile == source, compareProfile == dest else { return }
            comparison = nil
            lastError = error.localizedDescription
        }
    }

    private func handleProfilesError(_ error: Error) {
        if let profilesError = error as? HermesProfilesError, case .commandUnavailable = profilesError {
            profilesUnavailable = true
            profiles = [HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true, status: nil)]
            return
        }
        lastError = error.localizedDescription
    }
}
