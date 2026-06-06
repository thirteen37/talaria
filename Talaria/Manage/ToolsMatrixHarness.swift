import Foundation
import HermesKit

@MainActor
@Observable
final class ToolsMatrixHarness {
    var matrix: ToolsMatrix?
    var isLoading: Bool = false
    var lastError: String?
    var busyCells: Set<String> = []

    /// Hermes' known env vars (`GET /api/env`), used to drive each tool's config
    /// side panel. Loaded best-effort alongside the matrix — a failure here never
    /// blocks the matrix; the config buttons just don't appear.
    var envVars: [DashboardEnvVar] = []
    /// The tool whose config side panel is open, or nil when closed. Drives the
    /// `PlatformSplit` secondary pane in ``ToolsView``.
    var selectedToolID: String?
    /// Env-var names with an in-flight save/delete, so their field controls
    /// disable while the request is outstanding. (Reveal has its own per-field
    /// spinner inside ``RevealableSecretField``.)
    var envBusy: Set<String> = []
    /// Bumped after every env reload so a revealed secret re-masks rather than
    /// lingering in cleartext past a write/refresh.
    private(set) var remaskToken: Int = 0

    /// Toolset id → its individual function names (from `/api/tools/toolsets`).
    /// A tool's config env vars reference these function names (e.g. `web_search`),
    /// not the toolset id (`web`), so this map bridges the two. Best-effort: empty
    /// when the route is unavailable, which falls back to direct id matching.
    private var toolsetFunctions: [String: Set<String>] = [:]

    private let runner: HermesAdminRunning?
    private let client: DashboardClient

    init(client: DashboardClient, runner: HermesAdminRunning?) {
        self.client = client
        self.runner = runner
    }

    var hasRunner: Bool { runner != nil }

    func refresh() async {
        guard let runner else {
            matrix = nil
            envVars = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        // Env vars + toolset function lists load concurrently with the matrix and
        // are best-effort — the matrix is the primary content, so an `/api/env` or
        // `/api/tools/toolsets` failure must not clear it or raise the banner.
        async let envFetch = loadEnvVars()
        async let toolsetFetch = loadToolsetFunctions()
        let platforms = await platformColumns()
        do {
            matrix = try await HermesTools.loadMatrix(runner: runner, platforms: platforms)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        envVars = await envFetch
        toolsetFunctions = await toolsetFetch
        pruneSelectionIfUnconfigurable()
    }

    // MARK: - Per-tool env config

    /// The env vars Hermes links to the toolset `tool`, set vars first then
    /// alphabetical. A var matches when its `tools` array names one of the
    /// toolset's functions (the normal case — tool vars reference function names
    /// like `web_search`), or names the toolset id directly (a safety net for
    /// any var tagged with the id itself). Empty when nothing maps.
    func configVars(for tool: String) -> [DashboardEnvVar] {
        let functions = toolsetFunctions[tool] ?? []
        return envVars
            .filter { envVar in
                let tagged = Set(envVar.tools)
                return tagged.contains(tool) || !tagged.isDisjoint(with: functions)
            }
            .sorted { lhs, rhs in
                if lhs.isSet != rhs.isSet { return lhs.isSet }
                return lhs.name < rhs.name
            }
    }

    /// Whether `tool` has ≥1 configurable env var — gates the row's Config button.
    func hasConfig(for tool: String) -> Bool {
        !configVars(for: tool).isEmpty
    }

    func saveEnv(key: String, value: String) async {
        envBusy.insert(key)
        defer { envBusy.remove(key) }
        do {
            try await client.setEnvVar(key: key, value: value)
            // Clear any prior failure: reloadEnvVars() skips the full refresh
            // (for the matrix-column optimization), so unlike GatewayView it
            // won't reset the banner on its own.
            lastError = nil
            await reloadEnvVars()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteEnv(key: String) async {
        envBusy.insert(key)
        defer { envBusy.remove(key) }
        do {
            try await client.deleteEnvVar(key: key)
            lastError = nil
            await reloadEnvVars()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetches one var's unredacted value on demand. The plaintext lives only in
    /// the requesting field's view state, so it can't linger past that field.
    func revealEnv(key: String) async -> String? {
        do {
            let value = try await client.revealEnvVar(key: key)
            lastError = nil
            return value
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Re-reads env vars after a write — env-only, so the matrix isn't re-listed
    /// (keeping the toggle fan-out optimization intact). Re-masks revealed
    /// secrets and closes the panel if the tool lost its last configurable var.
    private func reloadEnvVars() async {
        envVars = await loadEnvVars()
        remaskToken &+= 1
        pruneSelectionIfUnconfigurable()
    }

    private func loadEnvVars() async -> [DashboardEnvVar] {
        (try? await client.listEnvVars()) ?? []
    }

    private func loadToolsetFunctions() async -> [String: Set<String>] {
        guard let toolsets = try? await client.getToolsets() else { return [:] }
        return Dictionary(
            toolsets.map { ($0.name, Set($0.tools)) },
            uniquingKeysWith: { $0.union($1) }
        )
    }

    private func pruneSelectionIfUnconfigurable() {
        if let tool = selectedToolID, !hasConfig(for: tool) {
            selectedToolID = nil
        }
    }

    func setEnabled(tool: String, platform: String, enabled: Bool) async {
        guard let runner else { return }
        let id = cellID(tool: tool, platform: platform)
        busyCells.insert(id)
        defer { busyCells.remove(id) }

        do {
            if enabled {
                try await HermesTools.enable(runner: runner, name: tool, platform: platform)
            } else {
                try await HermesTools.disable(runner: runner, name: tool, platform: platform)
            }
            await refreshColumn(platform, runner: runner)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-lists only the toggled platform and merges its column back in, instead
    /// of a full `refresh()` (which fans out a `tools list` per platform plus a
    /// `/api/status` call). Toggling one platform can't change another's state,
    /// so this keeps a checkbox flip to a single CLI spawn — important over
    /// remote SSH with several gateway platforms. Falls back to a full refresh
    /// only if there's no existing matrix to merge into.
    private func refreshColumn(_ platform: String, runner: HermesAdminRunning) async {
        guard let current = matrix else {
            await refresh()
            return
        }
        do {
            let rows = try await HermesTools.list(runner: runner, platform: platform)
            matrix = current.replacingColumn(platform, with: rows)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func isBusy(tool: String, platform: String) -> Bool {
        busyCells.contains(cellID(tool: tool, platform: platform))
    }

    private func platformColumns() async -> [String] {
        do {
            let status = try await client.getStatus()
            let reported = (status.gatewayPlatforms ?? [:])
                .keys
                .filter { $0 != "cli" }
                .sorted()
            return ["cli"] + reported
        } catch {
            return ["cli"]
        }
    }

    private func cellID(tool: String, platform: String) -> String {
        "\(platform)\t\(tool)"
    }
}
