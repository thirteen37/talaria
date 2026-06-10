import Foundation

public struct HermesProfileInfo: Equatable, Sendable, Identifiable {
    public let name: String
    /// True for the default profile (`~/.hermes`), which Hermes conventionally
    /// names `default`. Set from an explicit `Default` column / marker, or
    /// inferred from the name.
    public let isDefault: Bool
    /// Optional runtime status (`running`, `stopped`, …) when the CLI surfaces
    /// one; nil otherwise.
    public let status: String?
    /// Configured model for the profile (e.g. `anthropic/claude-sonnet-4.6`),
    /// surfaced by the dashboard's `GET /api/profiles`. Nil when unknown.
    public let model: String?

    public var id: String { name }

    public init(
        name: String,
        isDefault: Bool,
        status: String? = nil,
        model: String? = nil
    ) {
        self.name = name
        self.isDefault = isDefault
        self.status = status
        self.model = model
    }
}

/// One environment variable a distribution declares it needs (`env_requires`
/// in `distribution.yaml`, also echoed by `hermes profile info`). Shared by
/// ``ProfileDistributionInfo`` (the parsed `info` output) and
/// ``DistributionManifest`` (the authored manifest), so the info display and the
/// manifest editor speak the same model.
public struct EnvRequirement: Equatable, Sendable, Identifiable {
    /// The variable name, e.g. `OPENAI_API_KEY`. Drives the Environment-screen
    /// `EntityLink`.
    public let name: String
    /// Optional human description of what the variable is for.
    public let description: String?
    /// Whether the distribution treats this var as mandatory. Defaults to
    /// `true` — most declared vars are required, and a manifest that omits the
    /// flag conventionally means required.
    public let required: Bool
    /// Fallback value used when an **optional** var isn't provided (`default` in
    /// the manifest). `nil` when the manifest omits it.
    public let defaultValue: String?

    public var id: String { name }

    public init(name: String, description: String? = nil, required: Bool = true, defaultValue: String? = nil) {
        self.name = name
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
    }
}

/// A profile's distribution manifest as surfaced by `hermes profile info`, or
/// the sentinel state for a profile that has no `distribution.yaml`.
///
/// `parseInfo(_:profile:)` is deliberately **tolerant** (mirroring
/// ``HermesProfiles/parse(_:)``): it best-effort extracts the headline fields
/// from `key: value` lines and keeps the full `rawText` verbatim for display, so
/// a format tweak in a future Hermes never blanks the screen — at worst a single
/// headline field goes unrecognised while `rawText` still shows everything.
public struct ProfileDistributionInfo: Equatable, Sendable {
    /// False when Hermes reported `Profile 'X' is not a distribution (no
    /// distribution.yaml).` — the headline fields are then all nil/empty and the
    /// UI offers "Author a distribution.yaml" instead of a manifest view.
    public let isDistribution: Bool
    public let name: String?
    public let version: String?
    public let description: String?
    public let author: String?
    public let license: String?
    /// The recorded upstream the distribution was installed from (git URL / dir).
    public let source: String?
    /// A Hermes version constraint the distribution declares (e.g. `>=0.15.0`).
    public let hermesRequires: String?
    public let envRequires: [EnvRequirement]
    /// The verbatim `hermes profile info` output, always retained for display.
    public let rawText: String

    public init(
        isDistribution: Bool,
        name: String? = nil,
        version: String? = nil,
        description: String? = nil,
        author: String? = nil,
        license: String? = nil,
        source: String? = nil,
        hermesRequires: String? = nil,
        envRequires: [EnvRequirement] = [],
        rawText: String = ""
    ) {
        self.isDistribution = isDistribution
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.license = license
        self.source = source
        self.hermesRequires = hermesRequires
        self.envRequires = envRequires
        self.rawText = rawText
    }
}

public enum HermesProfilesError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let detail):
            return "Profile command unavailable in this Hermes version: \(detail)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes profile failed (exit \(code))" : trimmed
        }
    }
}

public enum HermesProfiles {
    /// Conventional name of the default profile (lives at `~/.hermes`).
    public static let defaultProfileName = "default"

    /// Global `-p <name>` flag tokens that scope a `hermes` invocation to a
    /// named profile, or empty for the default profile (`nil`/empty/`default`
    /// all yield no `-p`, which is what the window's shared dashboard already
    /// serves). Used for a local argv where no shell quoting is applied —
    /// `[hermesPath] + cliFlag(name) + ["acp"]` and friends.
    public static func cliFlag(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != defaultProfileName else { return [] }
        return ["-p", name]
    }

    /// Like ``cliFlag(_:)`` but single-quotes the name for a remote shell
    /// command line, matching how the hermes path and env vars are quoted.
    public static func remoteCLIFlag(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != defaultProfileName else { return [] }
        return ["-p", ShellQuoting.shellQuote(name)]
    }

    // MARK: - Distributions
    //
    // Profile reads + clone/rename/delete are dashboard-only (see #120); these
    // distribution commands have **no** dashboard route, so they're the one
    // remaining CLI surface here, gated behind the `profileDistributions`
    // capability and driven through the admin runner like the Skills Hub.

    /// Installs a distribution from `source` (a git URL or local dir) into a new
    /// profile. `-y` skips the manifest-preview confirmation (non-interactive);
    /// the optional flags mirror the CLI: `--name` overrides the derived profile
    /// name, `--alias` records the source as an alias, `--force` overwrites an
    /// existing profile. Returns the trimmed stdout (manifest preview + result
    /// line) for the confirmation banner.
    @discardableResult
    public static func install(
        runner: HermesAdminRunning,
        source: String,
        name: String? = nil,
        alias: Bool = false,
        force: Bool = false
    ) async throws -> String {
        var arguments = ["profile", "install", source]
        if let name, !name.isEmpty { arguments += ["--name", name] }
        if alias { arguments.append("--alias") }
        if force { arguments.append("--force") }
        arguments.append("-y")
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-pulls a distribution profile's recorded source. `-y` skips the
    /// confirmation; `--force-config` also overwrites `config.yaml` (otherwise
    /// the user's config is preserved). Returns trimmed stdout.
    @discardableResult
    public static func update(
        runner: HermesAdminRunning,
        name: String,
        forceConfig: Bool = false
    ) async throws -> String {
        var arguments = ["profile", "update", name]
        if forceConfig { arguments.append("--force-config") }
        arguments.append("-y")
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a profile's distribution manifest. Returns
    /// `ProfileDistributionInfo(isDistribution: false)` for the
    /// `not a distribution` sentinel — that's a normal, non-error state (a
    /// plain profile), so it's detected *before* `ensureSuccess` in case Hermes
    /// signals it with a non-zero exit.
    public static func info(runner: HermesAdminRunning, name: String) async throws -> ProfileDistributionInfo {
        let result = try await runner.run(HermesAdminCommand(arguments: ["profile", "info", name]))
        // The sentinel can land on either stream depending on the build; check
        // both before treating a non-zero exit as a hard failure.
        if isNotADistribution(result.stdout) || isNotADistribution(result.stderr) {
            return ProfileDistributionInfo(isDistribution: false, rawText: nonEmptyOutput(result))
        }
        try ensureSuccess(result)
        return parseInfo(result.stdout, profile: name)
    }

    /// Exports a profile to a `.tar.gz` at `outputPath` on the host running
    /// hermes (local disk, or the remote host for an SSH profile).
    public static func export(runner: HermesAdminRunning, name: String, outputPath: String) async throws {
        let result = try await runner.run(HermesAdminCommand(
            arguments: ["profile", "export", name, "-o", outputPath]
        ))
        try ensureSuccess(result)
    }

    /// Imports a profile from a `.tar.gz` at `archivePath` on the host running
    /// hermes. `--name` overrides the imported profile name. Returns trimmed
    /// stdout (the result line) for the confirmation banner.
    @discardableResult
    public static func importArchive(
        runner: HermesAdminRunning,
        archivePath: String,
        name: String? = nil
    ) async throws -> String {
        var arguments = ["profile", "import", archivePath]
        if let name, !name.isEmpty { arguments += ["--name", name] }
        let result = try await runner.run(HermesAdminCommand(arguments: arguments))
        try ensureSuccess(result)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolves a profile's home directory — the parent of the path
    /// `hermes [-p name] config path` prints. Used to locate where
    /// `distribution.yaml` lives and where the publish git script runs.
    ///
    /// `config` is not a `profile` subcommand, so when this runs through a
    /// ``ProfileScopedHermesAdminRunner`` scoped to a *named* window profile the
    /// wrapper prepends its own `-p`, yielding a doubled flag where hermes'
    /// argparse takes the last value (this method's explicit `-p name`). On the
    /// common default-profile window the wrapper is transparent.
    public static func profileDirectory(runner: HermesAdminRunning, name: String) async throws -> String {
        let result = try await runner.run(HermesAdminCommand(
            arguments: cliFlag(name) + ["config", "path"]
        ))
        try ensureSuccess(result)
        let configPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configPath.isEmpty else {
            throw HermesProfilesError.commandFailed(exitCode: result.exitCode, stderr: "config path returned no output")
        }
        return (configPath as NSString).deletingLastPathComponent
    }

    /// Tolerant parser for `hermes profile info`. Best-effort maps `key: value`
    /// headline lines and an `env_requires:` block to ``ProfileDistributionInfo``
    /// fields while always retaining `rawText`. Caller guarantees this is only
    /// invoked for an actual distribution (the sentinel is handled in `info`).
    public static func parseInfo(_ text: String, profile: String) -> ProfileDistributionInfo {
        var fields: [String: String] = [:]
        var envRequires: [EnvRequirement] = []
        var inEnvBlock = false
        var pending: (name: String, description: String?, required: Bool, defaultValue: String?)?

        func flushPending() {
            if let p = pending {
                envRequires.append(EnvRequirement(
                    name: p.name,
                    description: p.description,
                    required: p.required,
                    defaultValue: p.defaultValue
                ))
                pending = nil
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let indented = raw.first == " " || raw.first == "\t"
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if inEnvBlock {
                // An env item: `- NAME` or `- name: NAME`.
                if line.hasPrefix("-") {
                    flushPending()
                    let item = line.dropFirst().trimmingCharacters(in: .whitespaces)
                    if let (k, v) = splitKeyValue(item), k.lowercased() == "name" {
                        pending = (v, nil, true, nil)
                    } else {
                        pending = (item, nil, true, nil)
                    }
                    continue
                }
                // An indented attribute of the current item.
                if indented, var p = pending, let (k, v) = splitKeyValue(line) {
                    switch k.lowercased() {
                    case "description": p.description = v
                    case "required": p.required = parseBoolLoose(v)
                    case "default": p.defaultValue = v
                    default: break
                    }
                    pending = p
                    continue
                }
                // A non-indented line ends the env block.
                flushPending()
                inEnvBlock = false
            }

            guard let (key, value) = splitKeyValue(line) else { continue }
            let normalizedKey = key.lowercased().replacingOccurrences(of: " ", with: "_")
            if normalizedKey == "env_requires" || normalizedKey == "environment" {
                inEnvBlock = true
                continue
            }
            if fields[normalizedKey] == nil, !value.isEmpty {
                fields[normalizedKey] = value
            }
        }
        flushPending()

        return ProfileDistributionInfo(
            isDistribution: true,
            name: fields["name"],
            version: fields["version"],
            description: fields["description"],
            author: fields["author"],
            license: fields["license"],
            source: fields["source"],
            hermesRequires: fields["hermes_requires"] ?? fields["requires"] ?? fields["hermes"],
            envRequires: envRequires,
            rawText: text
        )
    }

    /// Splits a `key: value` line into its trimmed parts, or nil when there's no
    /// colon. A value may itself contain colons (e.g. a URL), so only the first
    /// colon splits.
    static func splitKeyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
            // Strip surrounding YAML quotes if present.
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func parseBoolLoose(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return !(lowered == "false" || lowered == "no" || lowered == "0")
    }

    private static func isNotADistribution(_ text: String) -> Bool {
        text.lowercased().contains("is not a distribution")
    }

    private static func nonEmptyOutput(_ result: HermesAdminResult) -> String {
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Profiles that drive the window's Hermes-profile switcher, sourced solely
    /// from the dashboard `/api/profiles` route. The dashboard reports clean
    /// names and a structured default flag, so this never parses the decorated
    /// CLI `profile list` table (whose default-marker glyph would otherwise leak
    /// into the menu — the bug this path replaces).
    ///
    /// Returns a default-only list when the dashboard client isn't online yet or
    /// the call fails — the switcher then shows a `default`-only menu. The caller
    /// re-runs this once `dashboardClient` becomes available to upgrade to the
    /// live list.
    public static func selectorProfiles(client: DashboardClient?) async -> [HermesProfileInfo] {
        guard let client else { return defaultOnly }
        do {
            return try await client.listProfiles().map {
                HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, status: nil)
            }
        } catch {
            return defaultOnly
        }
    }

    /// The default-only state for the switcher: a single `default` row, used
    /// while the dashboard isn't online yet or after a failed read. The sidebar
    /// shows it as a `default`-only menu.
    private static var defaultOnly: [HermesProfileInfo] {
        [HermesProfileInfo(name: defaultProfileName, isDefault: true, status: nil)]
    }

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        // hermes (and Rich) frequently print the actual error to **stdout**, not
        // stderr — so scan and surface both. Without the stdout fallback a
        // stderr-empty failure collapsed to the useless "hermes profile failed
        // (exit N)" banner, hiding the real cause.
        let combined = (result.stderr + "\n" + result.stdout).lowercased()
        // Mirror HermesSkills: match only command-shape failures so we don't
        // mislabel `env: hermes: No such file or directory` (a PATH failure)
        // as "version too old".
        if combined.contains("unknown command")
            || combined.contains("no such command")
            || combined.contains("no such subcommand") {
            throw HermesProfilesError.commandUnavailable(combinedOutput(result))
        }
        throw HermesProfilesError.commandFailed(exitCode: result.exitCode, stderr: combinedOutput(result))
    }

    /// The failure detail to surface: stderr if present, else stdout (where
    /// hermes/Rich often write the error), else neither.
    private static func combinedOutput(_ result: HermesAdminResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
