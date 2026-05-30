import HermesKit
import SwiftUI

/// View-model for the single-profile config editor. Edits the config of the
/// window's **active** Hermes profile — the window dashboard is already scoped
/// to it (`hermes -p <name>`), so the editor simply talks to that dashboard via
/// the injected `defaultClient` provider; it no longer acquires its own
/// profile-scoped dashboard. Comparison state is additive — a compact (iPhone)
/// variant can reuse this harness and simply never set `comparing`.
@MainActor
@Observable
final class ConfigEditorHarness {
    enum Mode: String, CaseIterable, Identifiable {
        case structured
        case yaml
        var id: String { rawValue }
        var label: String { self == .structured ? "Structured" : "YAML" }
    }

    /// Profiles on the server (from the window) — only the compare dropdown's
    /// source of options now; the edit target is fixed to `editedProfileName`.
    /// Mutable because the window's enumeration can land after the editor opens
    /// (a slow remote `profile list`); the container feeds updates in via
    /// ``setAvailableProfiles(_:)`` so the dropdown isn't stuck empty.
    private(set) var profiles: [HermesProfileInfo]
    /// The Hermes profile this editor edits (the window's active profile). Used
    /// by the on-disk degraded read and as the comparison source.
    let editedProfileName: String

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
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?

    // Serializes comparison reads so rapid selection changes don't fire
    // concurrent NIO-SSH reads that race host-key verification.
    private var compareTask: Task<Void, Never>?
    // Serializes config loads so a refresh can't run overlapping GETs.
    private var loadTask: Task<Void, Never>?

    init(
        profiles: [HermesProfileInfo],
        editedProfileName: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        profile: ServerProfile,
        transfer: RemoteSnapshotTransfer?
    ) {
        self.profiles = profiles
        self.editedProfileName = editedProfileName
        self.defaultClientProvider = defaultClient
        self.serverProfile = profile
        self.transfer = transfer
        // Default the compare target to the first other profile.
        self.compareProfile = profiles.first(where: { $0.name != editedProfileName })?.name ?? ""
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
        load()
    }

    func refresh() async {
        load()
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
        isLoading = true
        defer { isLoading = false }
        if let client = defaultClientProvider() {
            do {
                async let schemaResult = client.getConfigSchema()
                async let configResult = client.getConfig()
                let schema = try await schemaResult
                let config = try await configResult
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
                lastError = error.localizedDescription
            }
        } else {
            await loadDegraded()
        }
        if comparing { scheduleCompare() }
    }

    /// Re-runs the load when the window's dashboard comes online after an
    /// initial degraded render (the editor opened before the spawn finished).
    func reloadIfDashboardAppeared() {
        guard dashboardUnavailable, defaultClientProvider() != nil else { return }
        load()
    }

    private func loadDegraded() async {
        dashboardUnavailable = true
        schema = nil
        form = nil
        original = nil
        // Best-effort: show the on-disk config read-only so the surface isn't
        // empty while the dashboard is unreachable.
        do {
            let text = try await HermesConfigReader.read(
                profile: serverProfile,
                profileName: editedProfileName,
                transfer: transfer
            )
            yamlText = text
            mode = .yaml
        } catch {
            yamlText = ""
        }
    }

    // MARK: - Mode switching

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
        guard let client = defaultClientProvider() else {
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

    /// Refreshes the available profiles for the compare dropdown when the
    /// window's enumeration lands after the editor opened. Preserves a still-valid
    /// user compare choice; otherwise re-defaults it (and re-runs the comparison
    /// if one is active and was waiting on an empty list).
    func setAvailableProfiles(_ newProfiles: [HermesProfileInfo]) {
        guard newProfiles != profiles else { return }
        profiles = newProfiles
        if compareProfile.isEmpty || !newProfiles.contains(where: { $0.name == compareProfile }) {
            compareProfile = newProfiles.first(where: { $0.name != editedProfileName })?.name ?? ""
            if comparing, !compareProfile.isEmpty {
                scheduleCompare()
            }
        }
    }

    func toggleComparing() {
        comparing.toggle()
        if comparing {
            if compareProfile.isEmpty {
                compareProfile = profiles.first(where: { $0.name != editedProfileName })?.name ?? ""
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
        let source = editedProfileName
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
            guard compareProfile == dest else { return }
            let sourceDoc = try HermesConfigDocument.parse(sourceText)
            let destDoc = try HermesConfigDocument.parse(destText)
            comparison = ConfigComparison(source: sourceDoc, dest: destDoc)
            lastError = nil
        } catch {
            guard compareProfile == dest else { return }
            comparison = nil
            lastError = error.localizedDescription
        }
    }
}
