import Foundation

/// One `KEY=VALUE` assignment parsed out of a Hermes `.env` file.
public struct EnvFileEntry: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Order-preserving parser for a Hermes `.env` file. Mirrors Hermes'
/// `load_env` (`tools/skills_tool.py`): strip each line, skip blank /
/// `#`-prefixed / no-`=` lines, split on the **first** `=`, trim whitespace
/// around the key and value, then strip any surrounding run of `"` / `'` from
/// the value (a char-set trim, matching Python `value.strip().strip("\"'")`).
/// Hermes' `_sanitize_env_lines` corruption recovery is deliberately out of
/// scope — this is used only to enumerate custom keys for display.
public enum EnvFile {
    public static func parse(_ contents: String) -> [EnvFileEntry] {
        var entries: [EnvFileEntry] = []
        let quotes = CharacterSet(charactersIn: "\"'")
        // Split on any newline (`\.isNewline` covers `\n`, `\r`, and the
        // `\r\n` grapheme cluster — a plain `split(separator: "\n")` would miss
        // CRLF because Swift treats `\r\n` as one Character).
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: quotes)
            entries.append(EnvFileEntry(key: key, value: value))
        }
        return entries
    }
}

/// Locally-computed redacted preview for a custom var, mirroring Hermes
/// `mask_secret` (`redact.py`): empty → `""`; fewer than 12 chars → `"***"`;
/// otherwise the first four and last four characters joined by `...`. Used so a
/// custom var's list preview matches how Hermes redacts known secrets, without
/// shipping the plaintext to the UI.
public func redactEnvValue(_ value: String) -> String {
    if value.isEmpty { return "" }
    if value.count < 12 { return "***" }
    return "\(value.prefix(4))...\(value.suffix(4))"
}

public enum EnvFileError: Error, Equatable, Sendable, LocalizedError {
    /// No admin runner to resolve the `.env` path (e.g. iPad-local path).
    case runnerUnavailable
    /// A remote profile with no SSH transfer wired up.
    case transferUnavailable
    /// `hermes config env-path` returned nothing usable.
    case pathUnresolved
    /// The file existed but couldn't be read.
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runnerUnavailable:
            return "Couldn't list custom variables: no Hermes CLI runner available."
        case .transferUnavailable:
            return "Couldn't list custom variables: no SSH transfer available for this remote profile."
        case .pathUnresolved:
            return "Couldn't locate the Hermes .env file (`hermes config env-path` returned nothing)."
        case .readFailed(let detail):
            return "Couldn't read the Hermes .env file: \(detail)"
        }
    }
}

/// Reads the raw entries of a Hermes `.env` file. The Environment screen uses
/// this purely to **enumerate** keys (so user-named custom vars the dashboard's
/// `GET /api/env` doesn't know about still appear); all mutations stay on the
/// dashboard API.
public protocol EnvFileReading: Sendable {
    func read() async throws -> [EnvFileEntry]
}

/// Resolves the `.env` path via the (profile-scoped) admin runner
/// (`hermes config env-path`) and reads its contents — locally from the
/// filesystem for `.local` profiles, or over the existing SSH connection (the
/// same `exec cat` `RemoteSnapshotTransfer` snapshots use) for `.ssh`. A
/// missing `.env` is treated as "no custom vars" (empty), not an error, since a
/// fresh Hermes install legitimately has none.
public struct HermesEnvFileReader: EnvFileReading {
    private let runner: HermesAdminRunning?
    private let snapshotTransfer: RemoteSnapshotTransfer?
    private let isLocal: Bool
    /// The SSH profile, used to build the macOS `SFTPSubprocessTransfer`
    /// fallback when no transfer is injected (the system-`ssh` remote path) —
    /// mirroring ``HermesConfigReader``. Nil for local reads.
    private let profile: ServerProfile?

    public init(
        runner: HermesAdminRunning?,
        snapshotTransfer: RemoteSnapshotTransfer?,
        isLocal: Bool,
        profile: ServerProfile? = nil
    ) {
        self.runner = runner
        self.snapshotTransfer = snapshotTransfer
        self.isLocal = isLocal
        self.profile = profile
    }

    public func read() async throws -> [EnvFileEntry] {
        guard let runner else { throw EnvFileError.runnerUnavailable }
        let result = try await runner.run(HermesAdminCommand(arguments: ["config", "env-path"]))
        // `config env-path` prints the path on its own line; take the last
        // non-empty trimmed line so a stray banner line above it doesn't win.
        let path = result.stdout
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard let path, !path.isEmpty else { throw EnvFileError.pathUnresolved }

        let contents = isLocal ? try readLocal(path: path) : try await readRemote(path: path)
        return EnvFile.parse(contents)
    }

    private func readLocal(path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EnvFileError.readFailed(error.localizedDescription)
        }
    }

    private func readRemote(path: String) async throws -> String {
        // An injected transfer works on any platform (NIO on iOS / the macOS
        // NIO opt-in); otherwise fall back to the macOS `sftp` subprocess for
        // the system-`ssh` path — same resolution ``HermesConfigReader`` uses.
        let active: RemoteSnapshotTransfer
        if let snapshotTransfer {
            active = snapshotTransfer
        } else {
            #if os(macOS)
            guard let profile else { throw EnvFileError.transferUnavailable }
            active = SFTPSubprocessTransfer(profile: profile)
            #else
            throw EnvFileError.transferUnavailable
            #endif
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-env-\(UUID().uuidString).env")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await active.fetch(remotePath: path, to: tmpURL)
        } catch let error as SSHTransportError {
            // A missing remote `.env` is the "no custom vars yet" state, not a
            // failure — match the local `readLocal` behavior (returns ""). The
            // wording varies by transport: `cat`/OpenSSH-sftp say "No such file
            // or directory"; some SFTP servers say "… not found." Accept both so
            // a fresh-install host doesn't surface a persistent error banner.
            if case let .transferFailed(message) = error {
                let lowered = message.lowercased()
                if lowered.contains("no such file") || lowered.contains("not found") {
                    return ""
                }
            }
            throw EnvFileError.readFailed(error.message)
        } catch {
            throw EnvFileError.readFailed(error.localizedDescription)
        }

        do {
            return try String(contentsOf: tmpURL, encoding: .utf8)
        } catch {
            throw EnvFileError.readFailed(error.localizedDescription)
        }
    }
}
