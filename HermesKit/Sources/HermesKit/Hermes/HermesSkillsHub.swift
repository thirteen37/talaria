import Foundation

/// One row of `hermes skills list` — every installed skill, builtin/local/hub.
/// Modeled on ``ToolRow`` (the Tools CLI surface) since both are scraped from a
/// Rich box table over the admin runner.
public struct InstalledHubSkill: Equatable, Sendable, Identifiable {
    public let name: String
    /// Category folder, e.g. `creative`. Empty for uncategorized skills.
    public let category: String?
    /// The Source column. For a **hub** skill this is its *origin*
    /// (`official` / `github` / `clawhub` / `lobehub` / `skills-sh`); for a
    /// builtin it is exactly `builtin`; for a local skill exactly `local`.
    public let source: String
    /// Trust column (`builtin` / `local` / `community` / `trusted` /
    /// `official`). Optional so a leaner table still maps.
    public let trust: String?
    public let enabled: Bool

    public var id: String { name }

    /// True when this skill came from the Skills Hub and is therefore eligible
    /// for Update / Remove. `hermes skills list` renders a hub skill's Source as
    /// its origin (never the literal `hub`), while builtin/local rows always
    /// read exactly `builtin`/`local` (see `hermes_cli/skills_hub.py` `do_list`).
    /// So any Source outside that pair identifies a hub-managed skill.
    public var isHubManaged: Bool {
        let normalized = source.lowercased()
        return normalized != "builtin" && normalized != "local"
    }

    /// True when this skill was created locally (Source column reads exactly
    /// `local`) rather than shipped builtin or installed from the Skills Hub.
    public var isLocal: Bool { source.lowercased() == "local" }

    /// True when this skill shipped bundled with Hermes (Source column reads
    /// exactly `builtin`). Drives the **Reset** / **Repair** affordances.
    public var isBuiltin: Bool { source.lowercased() == "builtin" }

    /// True when this skill is an *official* Nous skill (Trust column reads
    /// `official`). A subset of builtins; gates the **Repair** (`repair-official`)
    /// action, which only makes sense for official-trust skills.
    public var isOfficial: Bool { trust?.lowercased() == "official" }

    public init(name: String, category: String?, source: String, trust: String?, enabled: Bool) {
        self.name = name
        self.category = category
        self.source = source
        self.trust = trust
        self.enabled = enabled
    }
}

/// One row of `hermes skills check` — a hub skill's upstream-update status.
public struct SkillUpdateStatus: Equatable, Sendable, Identifiable {
    public let name: String
    public let source: String
    /// `update_available` / `up_to_date` / `error` / … (verbatim from Hermes).
    public let status: String

    public var id: String { name }

    public var updateAvailable: Bool { status == "update_available" }

    public init(name: String, source: String, status: String) {
        self.name = name
        self.source = source
        self.status = status
    }
}

public enum HermesSkillsHubError: Error, Equatable, Sendable, LocalizedError {
    /// `skills` subcommand missing in this Hermes (argparse "no such command").
    case commandUnavailable(String)
    /// Non-zero exit.
    case commandFailed(exitCode: Int32, stderr: String)
    /// Exit 0, but stdout signaled a soft failure — the install/uninstall path
    /// returns 0 even when the security scan blocks, the bundle can't be
    /// fetched, or the user "cancels" (which a closed stdin triggers). The
    /// associated string is the offending line for surfacing in the UI.
    case operationRejected(String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let detail):
            return "Skills command unavailable in this Hermes version: \(detail)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes skills failed (exit \(code))" : trimmed
        case .operationRejected(let detail):
            return detail
        }
    }
}

/// Destination registry for `hermes skills publish`. The raw value is the
/// literal `--to` argument the CLI expects.
public enum SkillsPublishRegistry: String, CaseIterable, Sendable, Identifiable {
    case github
    case clawhub

    public var id: String { rawValue }
}

/// CLI-fallback for the Skills Hub *mutations* (install / update / uninstall)
/// and the installed/update-status reads that back them. Search lives in the
/// HTTP ``SkillsHubCatalog`` — the dashboard exposes no hub routes, so these
/// inherently-local, security-scanned operations run `hermes skills …` through
/// the admin runner, mirroring ``HermesTools``.
public enum HermesSkillsHub {
    /// Wide, color-free terminal so Rich doesn't wrap table cells (`COLUMNS`)
    /// or inject ANSI styling (`NO_COLOR`) into the text we scrape.
    static let tableEnvironment = ["COLUMNS": "400", "NO_COLOR": "1"]

    // MARK: - Mutations

    /// Installs a skill by identifier (`official/skills/foo`, `owner/repo/...`,
    /// or a direct `https://…/SKILL.md` URL). `--yes` skips only the *prompt* —
    /// the `skills_guard` security scan still runs and still blocks dangerous
    /// verdicts. Returns the trimmed stdout (scan report + result line) for the
    /// confirmation banner; throws `.operationRejected` on a soft failure.
    @discardableResult
    public static func install(runner: HermesAdminRunning, identifier: String) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "install", "--yes", "--", identifier]
        ))
        try ensureSuccess(result)
        try ensureNotSoftFailure(result.stdout, markers: installFailureMarkers)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Updates hub-installed skills — all of them, or just `name`. Runs
    /// non-interactively (`do_update` re-installs with `force=True`, bypassing
    /// the prompt). Returns trimmed stdout.
    @discardableResult
    public static func update(runner: HermesAdminRunning, name: String? = nil) async throws -> String {
        var arguments = ["skills", "update"]
        if let name { arguments += ["--", name] }
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a hub-installed skill. `hermes skills uninstall` has **no
    /// `--yes`** in v0.14.0 — it prompts via `input("Confirm [y/N]: ")`, and a
    /// closed stdin reads as "Cancelled" (exit 0, no removal). We feed `y\n` on
    /// stdin to confirm non-interactively; the `stdinInput` seam is honored only
    /// by the local macOS runner, so remote uninstall is deferred (see the
    /// remote runners' notes). Throws `.operationRejected` if the output still
    /// reports a cancel/error.
    public static func uninstall(runner: HermesAdminRunning, name: String) async throws {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "uninstall", "--", name],
            stdinInput: "y\n"
        ))
        try ensureSuccess(result)
        try ensureNotSoftFailure(result.stdout, markers: uninstallFailureMarkers)
    }

    // MARK: - Lifecycle (audit / reset / repair / opt-in-out / publish)

    /// Re-scans a hub skill and returns the scan report (`skills audit`). `name`
    /// is positional, passed after `--` so a name starting with `-` isn't read as
    /// a flag. Works over local **and** remote runners (no stdin prompt).
    @discardableResult
    public static func audit(runner: HermesAdminRunning, name: String) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "audit", "--", name]
        ))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clears a builtin skill's sync-manifest `user-modified` tracking
    /// (`skills reset`). The **safe** default (no `--restore`) only forgets the
    /// tracking — it doesn't re-copy the bundled version — so it needs no stdin
    /// prompt and runs over any runner. Returns trimmed stdout.
    @discardableResult
    public static func reset(runner: HermesAdminRunning, name: String) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "reset", "--", name]
        ))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Backfills an official skill's hub metadata (`skills repair-official`). The
    /// **safe** default (no `--restore`) only re-writes metadata — it doesn't
    /// restore files from the repo — so it needs no stdin prompt and runs over
    /// any runner. Returns trimmed stdout.
    @discardableResult
    public static func repairOfficial(runner: HermesAdminRunning, name: String) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "repair-official", "--", name]
        ))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops bundled (builtin) skills from seeding into this profile by writing
    /// the `.no-bundled-skills` marker (`skills opt-out`). The **safe** default
    /// (no `--remove`) leaves already-seeded copies in place. Returns trimmed
    /// stdout.
    @discardableResult
    public static func optOut(runner: HermesAdminRunning) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "opt-out"]
        ))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-enables bundled-skill seeding by removing the `.no-bundled-skills`
    /// marker (`skills opt-in`). With `sync` it also re-seeds immediately
    /// (`--sync`). Returns trimmed stdout.
    @discardableResult
    public static func optIn(runner: HermesAdminRunning, sync: Bool = false) async throws -> String {
        var arguments = ["skills", "opt-in"]
        if sync { arguments.append("--sync") }
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Publishes a **local** skill directory to a registry (`skills publish`).
    /// `path` is the skill *directory* (publish's positional arg), `registry` the
    /// `--to` destination, and `repo` the `owner/repo` slug — required for
    /// `github`, optional for `clawhub` (dropped when nil/empty). Returns trimmed
    /// stdout. Local-only in practice (it operates on a local directory).
    @discardableResult
    public static func publish(
        runner: HermesAdminRunning,
        path: String,
        registry: SkillsPublishRegistry,
        repo: String?
    ) async throws -> String {
        var arguments = ["skills", "publish", path, "--to", registry.rawValue]
        if let repo, !repo.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["--repo", repo]
        }
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reads

    /// Every installed skill (builtin / local / hub). Used to mark which rows in
    /// the dashboard skills list are hub-managed (`isHubManaged`).
    public static func listInstalled(runner: HermesAdminRunning) async throws -> [InstalledHubSkill] {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["skills", "list"], environment: tableEnvironment
        ))
        try ensureSuccess(result)
        return parseInstalledTable(result.stdout)
    }

    /// Upstream-update status for hub skills — all, or just `name`.
    public static func checkUpdates(runner: HermesAdminRunning, name: String? = nil) async throws -> [SkillUpdateStatus] {
        var arguments = ["skills", "check"]
        if let name { arguments += ["--", name] }
        let result = try await runner.run(HermesAdminCommand(
            arguments: arguments, environment: tableEnvironment
        ))
        try ensureSuccess(result)
        return parseCheckTable(result.stdout)
    }

    // MARK: - Parsing

    /// `skills list` table → `Name │ Category │ Source │ Trust │ Status`.
    public static func parseInstalledTable(_ text: String) -> [InstalledHubSkill] {
        parseRichRows(text).compactMap { cells in
            guard let name = cells.first, !name.isEmpty else { return nil }
            let status = cells.count > 4 ? cells[4] : ""
            return InstalledHubSkill(
                name: name,
                category: cells.count > 1 ? emptyToNil(cells[1]) : nil,
                source: cells.count > 2 ? cells[2] : "",
                trust: cells.count > 3 ? emptyToNil(cells[3]) : nil,
                enabled: status.lowercased() == "enabled"
            )
        }
    }

    /// `skills check` table → `Name │ Source │ Status`. Returns `[]` for the
    /// "No hub-installed skills to check." sentinel (printed instead of a table
    /// when nothing is hub-managed).
    public static func parseCheckTable(_ text: String) -> [SkillUpdateStatus] {
        parseRichRows(text).compactMap { cells in
            guard let name = cells.first, !name.isEmpty else { return nil }
            return SkillUpdateStatus(
                name: name,
                source: cells.count > 1 ? cells[1] : "",
                status: cells.count > 2 ? cells[2] : ""
            )
        }
    }

    /// Parses a Rich box-drawing table into rows of trimmed cells. Data rows
    /// start with the light `│` separator (the header uses the heavy `┃`, and
    /// border/title lines start with `┏ ┡ └ ━` or plain text), so filtering on a
    /// leading `│` isolates the body. A row whose first cell is empty is treated
    /// as a wrapped continuation of the previous row and its non-empty cells are
    /// appended column-wise — defensive, since `COLUMNS=400` normally prevents
    /// wrapping.
    static func parseRichRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("│") else { continue }
            var cells = line
                .split(separator: "│", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // The leading/trailing `│` borders produce empty outer elements.
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            guard !cells.isEmpty else { continue }

            if cells[0].isEmpty, !rows.isEmpty {
                var previous = rows[rows.count - 1]
                for index in cells.indices where !cells[index].isEmpty && index < previous.count {
                    previous[index] += previous[index].isEmpty ? cells[index] : " \(cells[index])"
                }
                rows[rows.count - 1] = previous
                continue
            }
            rows.append(cells)
        }
        return rows
    }

    // MARK: - Result classification

    /// Markers that mean a 0-exit `install` actually failed (the install path
    /// returns 0 after printing these and bailing).
    private static let installFailureMarkers = [
        "installation blocked", "installation cancelled", "error:",
        "could not fetch", "could not find", "use --force to reinstall",
    ]

    /// Markers that mean a 0-exit `uninstall` didn't remove anything (closed
    /// stdin → "Cancelled.", or a host-side error).
    private static let uninstallFailureMarkers = ["cancelled.", "error:"]

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        let stderr = result.stderr.lowercased()
        // Same argparse/Click "command not in this hermes" detection as
        // `HermesTools.ensureSuccess`, without swallowing `env: hermes: No such
        // file or directory` (a PATH miss, which is a genuine failure).
        if stderr.contains("unknown command")
            || stderr.contains("no such command")
            || stderr.contains("no such subcommand") {
            throw HermesSkillsHubError.commandUnavailable(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        throw HermesSkillsHubError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }

    /// Scans stdout for soft-failure markers (used by install/uninstall, which
    /// can print a failure and still exit 0). Throws `.operationRejected` with
    /// the offending line so the UI shows the actual reason.
    static func ensureNotSoftFailure(_ stdout: String, markers: [String]) throws {
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()
            if markers.contains(where: { lowered.contains($0) }) {
                throw HermesSkillsHubError.operationRejected(line)
            }
        }
    }

    private static func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
