import Foundation

/// Errors from the unified direct-file layer. The reader-specific wrappers
/// (``HermesSoulReader``, ``HermesConfigReader``, ``HermesEnvFileReader``) catch
/// these and re-throw their own typed errors so their public surfaces — and the
/// suites guarding them — stay unchanged.
public enum HermesFileStoreError: Error, Equatable, Sendable, LocalizedError {
    case notFound(path: String)
    case readFailed(String)
    case writeFailed(String)
    /// No remote transfer is available and none can be constructed on this
    /// platform (the macOS system-`ssh` `SFTPSubprocessTransfer` fallback only
    /// exists on macOS, and only with a profile to build it from).
    case transferUnavailable

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "File not found at \(path)."
        case .readFailed(let detail):
            return "Couldn't read file: \(detail)"
        case .writeFailed(let detail):
            return "Couldn't write file: \(detail)"
        case .transferUnavailable:
            return "No SSH transfer available for this remote profile."
        }
    }
}

/// Where a Hermes-managed file lives, resolved into a local URL (for `.local`
/// profiles) or a remote transfer path (for `.ssh`).
public enum HermesFileLocation: Sendable {
    /// Relative to the profile's Hermes home. Local: under the expanded home
    /// (`profile.hermesHome` or `~/.hermes`). Remote: via
    /// ``HermesHomePaths/relativePath(hermesHome:tail:)``.
    case profileRelative(tail: String)
    /// A path already resolved by some other means (e.g. `hermes config
    /// env-path`). Local: expanded for `~`. Remote: used verbatim (the SFTP /
    /// `cat` transports perform no shell expansion).
    case resolved(path: String)
    /// Relative to the **login user's home** (not the Hermes home) — e.g.
    /// `~/.hindsight/…`. Local: under `NSHomeDirectory()`. Remote: a bare
    /// relative `tail`, which SFTP / `cat` resolve against the SSH session's
    /// home (they can't expand `~`/`$HOME`), mirroring
    /// ``HermesHomePaths/relativePath(hermesHome:tail:)``.
    case homeRelative(tail: String)
}

/// One place that reads **and writes** the Hermes files with no dashboard route
/// — folding the local-`FileManager` / remote-transfer logic that
/// ``HermesSoulReader``, ``HermesConfigReader``, and ``HermesEnvFileReader``
/// used to each duplicate. Writes (the Memory editor) go through the same path
/// inverted: a local atomic write, or a temp file streamed through the
/// transport's `upload`.
public enum HermesFileStore {
    // MARK: - Read

    public static func read(
        profile: ServerProfile,
        location: HermesFileLocation,
        transfer: RemoteSnapshotTransfer?
    ) async throws -> String {
        switch profile.kind {
        case .local:
            return try readLocal(at: localURL(profile: profile, location: location))
        case .ssh:
            return try await readRemote(
                remotePath: remotePath(profile: profile, location: location),
                transfer: transfer,
                profile: profile
            )
        }
    }

    /// Reads a pre-resolved path where the caller already tracks local-vs-remote
    /// itself (the Environment screen resolves the `.env` path via `hermes config
    /// env-path` and knows whether the profile is local). `profile` is only used
    /// to build the macOS system-`ssh` `SFTPSubprocessTransfer` fallback for a
    /// remote read with no injected transfer.
    public static func read(
        resolvedPath: String,
        isLocal: Bool,
        transfer: RemoteSnapshotTransfer?,
        profile: ServerProfile?
    ) async throws -> String {
        if isLocal {
            return try readLocal(at: URL(fileURLWithPath: (resolvedPath as NSString).expandingTildeInPath))
        }
        return try await readRemote(remotePath: resolvedPath, transfer: transfer, profile: profile)
    }

    // MARK: - Write

    public static func write(
        _ content: String,
        profile: ServerProfile,
        location: HermesFileLocation,
        transfer: RemoteSnapshotTransfer?
    ) async throws {
        switch profile.kind {
        case .local:
            try writeLocal(content, to: localURL(profile: profile, location: location))
        case .ssh:
            try await writeRemote(
                content,
                remotePath: remotePath(profile: profile, location: location),
                transfer: transfer,
                profile: profile
            )
        }
    }

    // MARK: - Path resolution

    /// Local on-disk URL for a location. Mirrors the home resolution
    /// `HermesConfigReader`/`HermesSoulReader` used (`HermesDBConfiguration`'s
    /// `profile.hermesHome ?? ~/.hermes`).
    static func localURL(profile: ServerProfile, location: HermesFileLocation) -> URL {
        switch location {
        case .profileRelative(let tail):
            let home = profile.hermesHome.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent(".hermes", isDirectory: true)
            return home.appendingPathComponent(tail)
        case .resolved(let path):
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        case .homeRelative(let tail):
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(tail)
        }
    }

    /// Remote transfer path for a location.
    static func remotePath(profile: ServerProfile, location: HermesFileLocation) -> String {
        switch location {
        case .profileRelative(let tail):
            return HermesHomePaths.relativePath(hermesHome: profile.hermesHome, tail: tail)
        case .resolved(let path):
            return path
        case .homeRelative(let tail):
            // Bare relative path: SFTP / `cat` resolve it against the SSH
            // session's home (they don't expand `~`/`$HOME`).
            return tail
        }
    }

    // MARK: - Local I/O

    private static func readLocal(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HermesFileStoreError.notFound(path: url.path)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HermesFileStoreError.readFailed(error.localizedDescription)
        }
    }

    private static func writeLocal(_ content: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            throw HermesFileStoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Remote I/O

    /// Resolves the transfer to use: the injected one (any platform), else the
    /// macOS system-`ssh` `SFTPSubprocessTransfer` fallback. Throws
    /// `.transferUnavailable` when neither is possible.
    private static func resolveTransfer(
        _ transfer: RemoteSnapshotTransfer?,
        profile: ServerProfile?
    ) throws -> RemoteSnapshotTransfer {
        if let transfer { return transfer }
        #if os(macOS)
        guard let profile else { throw HermesFileStoreError.transferUnavailable }
        return SFTPSubprocessTransfer(profile: profile)
        #else
        throw HermesFileStoreError.transferUnavailable
        #endif
    }

    private static func readRemote(
        remotePath: String,
        transfer: RemoteSnapshotTransfer?,
        profile: ServerProfile?
    ) async throws -> String {
        let active = try resolveTransfer(transfer, profile: profile)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-filestore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await active.fetch(remotePath: remotePath, to: tmpURL)
        } catch let error as SSHTransportError {
            // The wording varies by transport: `cat`/OpenSSH-sftp say "No such
            // file or directory"; some SFTP servers say "… not found." Map both
            // to `.notFound` so callers can decide (soul/config surface it, env
            // and memory treat it as empty).
            if case let .transferFailed(message) = error {
                let lowered = message.lowercased()
                if lowered.contains("no such file") || lowered.contains("not found") {
                    throw HermesFileStoreError.notFound(path: remotePath)
                }
            }
            throw HermesFileStoreError.readFailed(error.message)
        } catch {
            throw HermesFileStoreError.readFailed(error.localizedDescription)
        }

        do {
            return try String(contentsOf: tmpURL, encoding: .utf8)
        } catch {
            throw HermesFileStoreError.readFailed(error.localizedDescription)
        }
    }

    private static func writeRemote(
        _ content: String,
        remotePath: String,
        transfer: RemoteSnapshotTransfer?,
        profile: ServerProfile?
    ) async throws {
        let active = try resolveTransfer(transfer, profile: profile)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-filestore-upload-\(UUID().uuidString)")
        do {
            try Data(content.utf8).write(to: tmpURL, options: .atomic)
        } catch {
            throw HermesFileStoreError.writeFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await active.upload(from: tmpURL, to: remotePath)
        } catch let error as SSHTransportError {
            throw HermesFileStoreError.writeFailed(error.message)
        } catch {
            throw HermesFileStoreError.writeFailed(error.localizedDescription)
        }
    }
}
