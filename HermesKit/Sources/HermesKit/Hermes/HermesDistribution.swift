import Foundation
import NIOCore
import Yams

// MARK: - Manifest model

/// An authored `distribution.yaml` manifest. Hermes has **no command** to create
/// one (the docs say it's hand-authored in the profile dir, then committed), so
/// Talaria writes it directly into the profile home via ``HermesFileStore`` —
/// the same deliberate direct-write exception the Memory editor uses. This model
/// backs the authoring form and round-trips through Yams.
public struct DistributionManifest: Equatable, Sendable {
    public var name: String
    public var version: String?
    public var description: String?
    public var author: String?
    public var license: String?
    /// A Hermes version constraint, e.g. `>=0.15.0`.
    public var hermesRequires: String?
    public var envRequires: [EnvRequirement]
    /// Files the distribution *owns* — overwritten on `profile update` rather
    /// than preserved as user data. `nil` omits the key entirely.
    public var distributionOwned: [String]?

    public init(
        name: String,
        version: String? = nil,
        description: String? = nil,
        author: String? = nil,
        license: String? = nil,
        hermesRequires: String? = nil,
        envRequires: [EnvRequirement] = [],
        distributionOwned: [String]? = nil
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.license = license
        self.hermesRequires = hermesRequires
        self.envRequires = envRequires
        self.distributionOwned = distributionOwned
    }

    /// Serialises to `distribution.yaml` text with a stable key order, omitting
    /// any unset field so the file stays minimal.
    public func encodeYAML() throws -> String {
        var mapping = Node.Mapping()
        mapping[Node("name")] = Node(name)
        if let version, !version.isEmpty { mapping[Node("version")] = Node(version) }
        if let description, !description.isEmpty { mapping[Node("description")] = Node(description) }
        if let author, !author.isEmpty { mapping[Node("author")] = Node(author) }
        if let license, !license.isEmpty { mapping[Node("license")] = Node(license) }
        if let hermesRequires, !hermesRequires.isEmpty { mapping[Node("hermes_requires")] = Node(hermesRequires) }
        if !envRequires.isEmpty {
            var items: [Node] = []
            for req in envRequires {
                var entry = Node.Mapping()
                entry[Node("name")] = Node(req.name)
                if let description = req.description, !description.isEmpty {
                    entry[Node("description")] = Node(description)
                }
                entry[Node("required")] = Node(req.required ? "true" : "false")
                if let defaultValue = req.defaultValue {
                    entry[Node("default")] = Node(defaultValue)
                }
                items.append(.mapping(entry))
            }
            mapping[Node("env_requires")] = Node.sequence(Node.Sequence(items))
        }
        if let distributionOwned, !distributionOwned.isEmpty {
            mapping[Node("distribution_owned")] = Node.sequence(
                Node.Sequence(distributionOwned.map { Node($0) })
            )
        }
        return try Yams.serialize(node: .mapping(mapping))
    }

    /// Parses `distribution.yaml` text. Throws ``DistributionManifestError`` on
    /// malformed YAML or a non-mapping root. A missing `name` defaults to empty
    /// (the editor surfaces it as invalid rather than rejecting the whole file).
    public init(parsingYAML text: String) throws {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw DistributionManifestError.parseFailed(String(describing: error))
        }
        guard let node else {
            self.init(name: "")
            return
        }
        guard case let .mapping(mapping) = node else {
            throw DistributionManifestError.notAMapping
        }
        func string(_ key: String) -> String? {
            mapping[Node(key)]?.string
        }
        var envRequires: [EnvRequirement] = []
        if let envNode = mapping[Node("env_requires")], case let .sequence(seq) = envNode {
            for item in seq {
                guard case let .mapping(itemMap) = item else {
                    // A bare string entry → just a required var name.
                    if let bare = item.string {
                        envRequires.append(EnvRequirement(name: bare))
                    }
                    continue
                }
                guard let varName = itemMap[Node("name")]?.string, !varName.isEmpty else { continue }
                let desc = itemMap[Node("description")]?.string
                let required = itemMap[Node("required")]?.bool ?? true
                let defaultValue = itemMap[Node("default")]?.string
                envRequires.append(EnvRequirement(
                    name: varName, description: desc, required: required, defaultValue: defaultValue
                ))
            }
        }
        var owned: [String]?
        if let ownedNode = mapping[Node("distribution_owned")], case let .sequence(seq) = ownedNode {
            owned = seq.compactMap { $0.string }
        }
        self.init(
            name: string("name") ?? "",
            version: string("version"),
            description: string("description"),
            author: string("author"),
            license: string("license"),
            hermesRequires: string("hermes_requires"),
            envRequires: envRequires,
            distributionOwned: owned
        )
    }
}

public enum DistributionManifestError: Error, Equatable, Sendable, LocalizedError {
    case parseFailed(String)
    case notAMapping

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let detail):
            return "Couldn't parse distribution.yaml: \(detail)"
        case .notAMapping:
            return "distribution.yaml must be a YAML mapping (key: value)."
        }
    }
}

// MARK: - Host shell seam

/// Runs an arbitrary shell command on the **host running hermes** — local disk
/// on macOS, or the remote host for an SSH profile. The distribution Publish
/// flow needs this to drive `git` where the profile actually lives; it's
/// deliberately separate from ``HermesAdminRunning`` (which only runs `hermes`
/// subcommands).
///
/// Concrete implementations are built per-platform alongside `adminRunner` /
/// `snapshotTransfer`: a local `/bin/sh -c` runner (macOS), and a remote runner
/// wrapping the same ``RemoteCommandRunning`` the snapshot pipeline uses
/// (system-ssh on the macOS default path, NIO-SSH on iOS and the macOS opt-in).
public protocol HostShellRunning: Sendable {
    /// Runs `script` (a `/bin/sh`-compatible command line) with an optional
    /// working directory, returning the captured result. Implementations must
    /// not throw on a non-zero exit — that's reported via
    /// ``RemoteCommandResult/exitCode`` so the caller can surface stderr.
    func runShell(_ script: String, workingDirectory: String?) async throws -> RemoteCommandResult
}

/// Host-shell over any ``RemoteCommandRunning`` (NIO-SSH on iOS / the macOS
/// opt-in, or a system-`ssh` runner on the macOS default path). The working
/// directory is applied by prefixing `cd <dir> &&`, since `RemoteCommandRunning`
/// execs a single command line with no cwd channel.
public struct RemoteCommandHostShell: HostShellRunning {
    private let runner: any RemoteCommandRunning
    private let timeout: TimeInterval

    public init(runner: any RemoteCommandRunning, timeout: TimeInterval = 120) {
        self.runner = runner
        self.timeout = timeout
    }

    public func runShell(_ script: String, workingDirectory: String?) async throws -> RemoteCommandResult {
        let command = HostShellScript.compose(script, workingDirectory: workingDirectory)
        return try await runner.run(command: command, timeout: .seconds(Int64(timeout)))
    }
}

/// Pure helper: composes a working-directory `cd` prefix onto a script. Shared
/// by the remote and local host shells so both quote the directory identically.
public enum HostShellScript {
    public static func compose(_ script: String, workingDirectory: String?) -> String {
        guard let dir = workingDirectory, !dir.isEmpty else { return script }
        return "cd \(ShellQuoting.shellQuote(dir)) && \(script)"
    }
}

#if os(macOS)
/// Host-shell on the local machine — `/bin/sh -c <script>` via ``OneShotProcess``.
public struct LocalHostShell: HostShellRunning {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func runShell(_ script: String, workingDirectory: String?) async throws -> RemoteCommandResult {
        let command = HostShellScript.compose(script, workingDirectory: workingDirectory)
        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            timeout: timeout
        )
        if result.timedOut {
            throw SSHTransportError.commandTimeout("host shell exceeded \(Int(timeout))s")
        }
        return RemoteCommandResult(
            exitCode: Int(result.exitCode),
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}

/// A ``RemoteCommandRunning`` over system `ssh` — the macOS default remote path
/// (which otherwise has no arbitrary-shell runner; ``RemoteHermesAdminRunner``
/// only runs `hermes`). Mirrors that runner's argument shape (`-T`, BatchMode,
/// port/identity) but execs an arbitrary command line. Used to back a
/// ``RemoteCommandHostShell`` for distribution Publish/Export on the system-ssh
/// path; the NIO opt-in and iOS use ``NIOSSHCommandRunner`` instead.
public struct SystemSSHCommandRunner: RemoteCommandRunning {
    private let profile: ServerProfile

    public init(profile: ServerProfile) {
        self.profile = profile
    }

    public func run(command: String, timeout: TimeAmount) async throws -> RemoteCommandResult {
        guard profile.kind == .ssh, let host = profile.host, !host.isEmpty else {
            throw SSHTransportError.other("profile is not an SSH profile")
        }
        var args: [String] = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if let port = profile.port { args += ["-p", String(port)] }
        if let identityFile = profile.identityFile { args += ["-i", identityFile] }
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        args += ["--", destination, command]

        let seconds = Double(timeout.nanoseconds) / 1_000_000_000
        let result = try await OneShotProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            timeout: seconds
        )
        if result.timedOut {
            throw SSHTransportError.commandTimeout("ssh command exceeded \(Int(seconds))s")
        }
        return RemoteCommandResult(
            exitCode: Int(result.exitCode),
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}
#endif

// MARK: - Publish

public enum DistributionPublishError: Error, Equatable, Sendable, LocalizedError {
    /// A git step exited non-zero. `output` is the combined stderr/stdout so the
    /// UI can show the verbatim failure (auth, conflict, …).
    case gitFailed(output: String)

    public var errorDescription: String? {
        switch self {
        case .gitFailed(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "git publish failed." : trimmed
        }
    }
}

/// Publishes a profile distribution to git by running `git init/add/commit/tag/
/// push` on the host where the profile lives, through a ``HostShellRunning``.
/// Git auth is delegated to the host (ssh-agent / credential helper) per the
/// security model — Talaria never handles git credentials; failures surface
/// verbatim.
public enum DistributionPublisher {
    /// The files a distribution publishes, per Hermes' profile-distribution
    /// model (`SOUL.md`, `config.yaml`, `mcp.json`, `skills/`, `cron/`, +
    /// `distribution.yaml`). This is deliberately an **allowlist**: a `git add
    /// -A` in the profile home would also stage the user's secrets (`.env`),
    /// memory (`MEMORY.md`/`USER.md`), and the sessions SQLite database and push
    /// them to the configured remote — a credential/privacy leak. Staging only
    /// known distribution content plus the manifest's `distribution_owned` paths
    /// means private data can never be published, even on a fresh repo with no
    /// `.gitignore` (e.g. the default `~/.hermes`).
    public static let standardPaths = [
        ".gitignore", "distribution.yaml", "SOUL.md", "config.yaml", "mcp.json", "skills", "cron",
    ]

    /// Hermes' hard-excluded paths — its "What's NOT in a distribution (ever)"
    /// list — written into the profile's `.gitignore` before staging. The
    /// allowlist staging already keeps these out of *our* commit, but persisting
    /// them in `.gitignore` protects against a later manual `git add -A`, and
    /// against a recipient who clones and re-publishes. Mirrors
    /// <https://hermes-agent.nousresearch.com/docs/user-guide/profile-distributions#whats-not-in-a-distribution-ever>.
    public static let excludedPaths = [
        "auth.json", ".env", "memories/", "sessions/",
        "state.db", "state.db-shm", "state.db-wal",
        "logs/", "workspace/", "plans/", "home/", "*_cache/", "local/",
    ]

    /// Builds the git script for one publish. A fresh repo (`.git` absent) is
    /// initialised, gets `main` as its branch, adds `origin`, and pushes with
    /// `-u … --tags`; an existing repo commits, (re)points `origin` if the URL
    /// changed, tags, and pushes. `ownedPaths` extends the staged allowlist with
    /// the manifest's `distribution_owned` entries. Pure + deterministic for
    /// testing.
    public static func script(
        isFreshRepo: Bool,
        remoteURL: String,
        version: String,
        message: String,
        ownedPaths: [String] = []
    ) -> String {
        let url = ShellQuoting.shellQuote(remoteURL)
        let tag = ShellQuoting.shellQuote(version)
        let msg = ShellQuoting.shellQuote(message)
        let ignore = ensureGitignoreCommand()
        let stage = stagingCommand(ownedPaths: ownedPaths)
        if isFreshRepo {
            return [
                "git init",
                ignore,
                stage,
                "git commit -m \(msg)",
                "git branch -M main",
                "git tag \(tag)",
                "git remote add origin \(url)",
                "git push -u origin main --tags",
            ].joined(separator: " && ")
        }
        // Add origin if absent, else repoint it to the requested URL.
        let ensureRemote = "if git remote get-url origin >/dev/null 2>&1; "
            + "then git remote set-url origin \(url); else git remote add origin \(url); fi"
        return [
            ignore,
            stage,
            "git commit -m \(msg)",
            "git tag \(tag)",
            ensureRemote,
            "git push origin HEAD --tags",
        ].joined(separator: " && ")
    }

    /// Idempotently ensures every ``excludedPaths`` entry is present in the
    /// profile's `.gitignore` (creating the file if absent) without clobbering
    /// existing user entries: each line is appended only when a whole-line
    /// fixed-string match is missing. The brace group returns the loop's status
    /// (0), so the `&&` chain continues.
    static func ensureGitignoreCommand() -> String {
        let entries = excludedPaths.map { ShellQuoting.shellQuote($0) }.joined(separator: " ")
        return "touch .gitignore && { for ig in \(entries); "
            + "do grep -qxF \"$ig\" .gitignore || printf '%s\\n' \"$ig\" >> .gitignore; done; }"
    }

    /// Stages only the distribution allowlist (each path added only when it
    /// exists, so a profile missing `cron/` or `mcp.json` doesn't fail the
    /// commit). Duplicate `ownedPaths` are dropped. The loop body ends in `:`
    /// so the whole command returns success and the `&&` chain continues.
    static func stagingCommand(ownedPaths: [String]) -> String {
        var paths = standardPaths
        for path in ownedPaths where !paths.contains(path) {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { paths.append(trimmed) }
        }
        let quoted = paths.map { ShellQuoting.shellQuote($0) }.joined(separator: " ")
        return "for p in \(quoted); do [ -e \"$p\" ] && git add -- \"$p\"; :; done"
    }

    /// Probes for an existing `.git`, then runs the matching script in
    /// `directory`. Returns the trimmed stdout of the push on success; throws
    /// ``DistributionPublishError/gitFailed(output:)`` on any non-zero step.
    @discardableResult
    public static func publish(
        shell: HostShellRunning,
        directory: String,
        remoteURL: String,
        version: String,
        message: String,
        ownedPaths: [String] = []
    ) async throws -> String {
        let probe = try await shell.runShell("test -d .git && echo yes || echo no", workingDirectory: directory)
        let isFreshRepo = !probe.stdout.contains("yes")
        let result = try await shell.runShell(
            script(
                isFreshRepo: isFreshRepo,
                remoteURL: remoteURL,
                version: version,
                message: message,
                ownedPaths: ownedPaths
            ),
            workingDirectory: directory
        )
        guard result.exitCode == 0 else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            throw DistributionPublishError.gitFailed(output: output)
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
