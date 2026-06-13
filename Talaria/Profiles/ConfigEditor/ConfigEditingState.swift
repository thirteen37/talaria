import HermesKit
import SwiftUI

/// Editing state for **one** profile's config: schema/form/original/working plus
/// the YAML mirror, the field bindings, and a non-destructive `save()`. Extracted
/// from `ConfigEditorHarness` so the single editor and each column of the
/// editable comparison are the same type, each scoped to its own profile and its
/// own dashboard client.
///
/// `profileName` is immutable for the instance's lifetime — selecting a different
/// profile builds a fresh state rather than mutating this one, which is why the
/// post-`await` guards collapse to a plain cancellation check (there is no
/// "selection moved on" to detect within a single instance).
///
/// The dashboard is reached by scoping the window's shared client to this
/// state's `profileName` (`?profile=<name>`) — the single dashboard serves every
/// profile — so this type stays platform-neutral and holds no process of its own.
@MainActor
@Observable
final class ConfigEditingState: Identifiable {
    enum Mode: String, CaseIterable, Identifiable {
        case structured
        case yaml
        var id: String { rawValue }
        var label: String { self == .structured ? "Structured" : "YAML" }
    }

    let profileName: String
    nonisolated var id: String { profileName }

    var mode: Mode = .structured
    private(set) var schema: DashboardConfigSchema?
    private(set) var form: ProfileConfigForm?
    /// Last GET — the non-destructive merge base and the dirty baseline.
    private(set) var original: JSONValue?
    /// Live edited config; structured controls mutate it, the YAML pane mirrors it.
    private(set) var working: JSONValue = .object([:])
    var yamlText: String = ""
    var yamlParseError: String?

    var isLoading = false
    /// Hard errors mirror to the top-of-window strip keyed "config" via the
    /// observer; the in-surface banner keeps only the dashboard-unavailable warning.
    var lastError: String? {
        didSet {
            if let lastError {
                banners?.surfaceError("config", lastError)
            } else {
                banners?.dismiss(key: "config")
            }
        }
    }
    /// Top-of-window banner hub (window-scoped); optional so a missing host
    /// degrades to no-op.
    var banners: BannerCenter?
    /// Dashboard client unavailable (not yet online, or spawn failed): the editor
    /// degrades to a read-only YAML view from the on-disk config and disables Save.
    var dashboardUnavailable = false

    // Dependencies
    private let defaultClientProvider: @MainActor () -> DashboardClient?
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?

    // Serializes config loads so a save-triggered reload can't overlap an
    // in-flight load (which would race the client resolution / clobber state).
    private var loadTask: Task<Void, Never>?

    init(
        profileName: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        serverProfile: ServerProfile,
        transfer: RemoteSnapshotTransfer?
    ) {
        self.profileName = profileName
        self.defaultClientProvider = defaultClient
        self.serverProfile = serverProfile
        self.transfer = transfer
    }

    var isDirty: Bool {
        guard let original, !dashboardUnavailable else { return false }
        return working != original
    }

    var canSave: Bool {
        isDirty && !isLoading && !dashboardUnavailable && yamlParseError == nil
    }

    // MARK: - Loading

    /// Schedules a config load, chained behind any in-flight load so two never
    /// overlap. Fire-and-forget: the view observes the state as it lands.
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
        let client = await currentClient()
        if Task.isCancelled { return }
        if let client {
            do {
                async let schemaResult = client.getConfigSchema()
                async let configResult = client.getConfig()
                let schema = try await schemaResult
                let config = try await configResult
                if Task.isCancelled { return }
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
                if Task.isCancelled { return }
                lastError = error.localizedDescription
            }
        } else {
            await loadDegraded()
        }
    }

    /// Awaits any in-flight load so a caller can sequence work behind it — used
    /// by the comparison to let the source side finish its first connect before
    /// the dest side starts acquiring (concurrent first-connects race host-key
    /// verification on the NIO transport).
    func awaitCurrentLoad() async {
        await loadTask?.value
    }

    /// Re-runs the load when the window's dashboard comes online after an initial
    /// degraded render (the editor opened before the spawn finished).
    func reloadIfDashboardAppeared() {
        guard dashboardUnavailable, defaultClientProvider() != nil else { return }
        load()
    }

    private func loadDegraded() async {
        if Task.isCancelled { return }
        dashboardUnavailable = true
        schema = nil
        form = nil
        original = nil
        // Best-effort: show the on-disk config read-only so the surface isn't
        // empty while the dashboard is unreachable.
        do {
            let text = try await HermesConfigReader.read(
                profile: serverProfile,
                profileName: profileName,
                transfer: transfer
            )
            if Task.isCancelled { return }
            yamlText = text
            mode = .yaml
        } catch {
            if Task.isCancelled { return }
            yamlText = ""
        }
    }

    /// This state's dashboard client: the window's shared client scoped to this
    /// state's profile (`?profile=<name>`). The single dashboard serves every
    /// profile, so there's no separate process to acquire — nil only while the
    /// window dashboard is still offline.
    private func currentClient() async -> DashboardClient? {
        defaultClientProvider()?.scoped(toProfile: profileName)
    }

    /// Cancels any in-flight load chain. No dashboard process is owned by this
    /// state (it borrows the window's), so there's nothing to release.
    func teardown() async {
        loadTask?.cancel()
        await loadTask?.value
        loadTask = nil
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
            // Don't leave the user staring at a structured form built from stale
            // values while their YAML doesn't parse.
            guard yamlParseError == nil else { return }
            mode = .structured
        }
    }

    private func regenerateYAML() {
        yamlText = (try? YAMLConfigCodec.yaml(from: working)) ?? yamlText
    }

    /// Re-parses the YAML pane into `working` on each edit so the structured view
    /// and dirty/save state stay in sync. Parse failures surface inline and leave
    /// `working` at its last good value.
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

    /// The field's value from the last load (`original`), not the live `working`
    /// edit. Used by the comparison's "Differences only" filter so the filter
    /// reads the loaded baseline — which changes only on load/save — instead of
    /// `working`, keeping per-keystroke edits from re-running the whole-union
    /// diff and from filtering a row out from under an active edit.
    func originalValue(for field: ConfigFormField) -> ConfigValue {
        guard let original, let leaf = ProfileConfigForm.value(at: field.key, in: original) else { return .missing }
        return ProfileConfigForm.configValue(from: leaf, schemaType: field.schema?.type)
    }

    private func setWorking(_ key: String, _ json: JSONValue) {
        working = ProfileConfigForm.setValue(json, at: key, in: working)
    }

    /// Writes a value coerced to `field`'s type into `working`, marking the state
    /// dirty. Used by the comparison's copy-across affordance to push one side's
    /// value onto the other through the same path the controls use.
    func copyValue(_ value: ConfigValue, into field: ConfigFormField) {
        switch value {
        case .string(let s): setWorking(field.key, .string(s))
        case .number(let n): setWorking(field.key, .number(n))
        case .bool(let b): setWorking(field.key, .bool(b))
        case .list(let items): setWorking(field.key, .array(items.map(JSONValue.string)))
        case .raw(let json): setWorking(field.key, json)
        case .missing: break
        }
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
        guard let client = await currentClient() else {
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
            banners?.surfaceSuccess("config", "Configuration saved")
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Backup (export / restore)

    /// YAML of the LAST-SAVED config (never the live edited buffer), for download.
    /// In the degraded (dashboard-unavailable) state `yamlText` already holds the
    /// on-disk config, so back that up instead.
    var backupYAML: String {
        if dashboardUnavailable { return yamlText }
        guard let original else { return "" }
        return (try? YAMLConfigCodec.yaml(from: original)) ?? ""
    }

    /// Whether there's anything to back up. Mirrors `backupYAML` being non-empty
    /// but without serializing — this is read on every toolbar recomputation
    /// (i.e. each keystroke), so it must stay cheap.
    var canExportBackup: Bool {
        if dashboardUnavailable { return !yamlText.isEmpty }
        return original != nil
    }

    var backupFilename: String { "\(profileName)-config.yaml" }

    /// Parses an imported file and writes it to the server as the whole document
    /// (mirrors YAML-mode save), then reloads. No-op without a live dashboard.
    func restore(fromYAML text: String) async {
        guard !dashboardUnavailable else { lastError = "Dashboard is unavailable; can't restore."; return }
        let parsed: JSONValue
        do { parsed = try YAMLConfigCodec.jsonValue(fromYAML: text) }
        catch { lastError = "Imported file isn't valid config YAML: \(error.localizedDescription)"; return }
        // A blank / whitespace / comments-only file parses to an empty object;
        // PUTting it would silently wipe the saved config, so reject it instead.
        if case .object(let o) = parsed, o.isEmpty {
            lastError = "Imported file is empty; nothing to restore."
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let client = await currentClient() else { lastError = "Dashboard is unavailable; can't restore."; return }
        do { try await client.updateConfig(parsed); load() }
        catch { lastError = error.localizedDescription }
    }
}
