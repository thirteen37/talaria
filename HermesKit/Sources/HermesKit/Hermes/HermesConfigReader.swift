import Foundation

public enum HermesConfigReaderError: Error, Equatable, Sendable, LocalizedError {
    case notFound(path: String)
    case readFailed(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No config.yaml found at \(path)."
        case .readFailed(let detail):
            return "Couldn't read config.yaml: \(detail)"
        case .unsupportedPlatform:
            return "Reading a remote profile's config requires the macOS host."
        }
    }
}

/// Reads a profile's raw `config.yaml` bytes — locally for `.local` profiles,
/// or over SSH (via an injected ``RemoteSnapshotTransfer``) for `.ssh`. The
/// caller injects whichever transport the app selected (NIO `cat` with the
/// keychain/host-key wiring, or system-`sftp`); both resolve the home-relative
/// path this builds against the login user's `$HOME` — SFTP relative to its
/// start dir, `cat` relative to the exec session's CWD — so no remote shell
/// expansion is needed.
public enum HermesConfigReader {
    /// Path of a profile's config relative to its **Hermes home**:
    /// `config.yaml` for the default profile, `profiles/<name>/config.yaml`
    /// otherwise.
    public static func configRelativePath(profileName: String) -> String {
        if profileName == HermesProfiles.defaultProfileName {
            return "config.yaml"
        }
        return "profiles/\(profileName)/config.yaml"
    }

    /// Remote path handed to the SFTP transfer. The SFTP server resolves
    /// relative paths against the login user's `$HOME`, so `nil`/`~` homes
    /// become **relative** paths (no shell expansion required); an absolute
    /// home stays absolute. Mirrors ``RemoteSnapshot/remoteStateDBPath(hermesHome:)``
    /// but emits relative (not `$HOME/…`) paths for the implicit-home cases.
    public static func remoteConfigPath(hermesHome: String?, profileName: String) -> String {
        HermesHomePaths.relativePath(hermesHome: hermesHome, tail: configRelativePath(profileName: profileName))
    }

    public static func read(
        profile: ServerProfile,
        profileName: String,
        transfer: RemoteSnapshotTransfer? = nil
    ) async throws -> String {
        switch profile.kind {
        case .local:
            return try readLocal(profile: profile, profileName: profileName)
        case .ssh:
            return try await readRemote(profile: profile, profileName: profileName, transfer: transfer)
        }
    }

    private static func readLocal(profile: ServerProfile, profileName: String) throws -> String {
        // Resolve home exactly like `HermesDBConfiguration.forProfile`.
        let home = profile.hermesHome.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".hermes", isDirectory: true)
        let url = home.appendingPathComponent(configRelativePath(profileName: profileName))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HermesConfigReaderError.notFound(path: url.path)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HermesConfigReaderError.readFailed(error.localizedDescription)
        }
    }

    private static func readRemote(
        profile: ServerProfile,
        profileName: String,
        transfer: RemoteSnapshotTransfer?
    ) async throws -> String {
        // An injected transfer works on any platform; the SFTP-subprocess
        // default is macOS-only (iPadOS later injects a NIO transfer).
        let active: RemoteSnapshotTransfer
        if let transfer {
            active = transfer
        } else {
            #if os(macOS)
            active = SFTPSubprocessTransfer(profile: profile)
            #else
            throw HermesConfigReaderError.unsupportedPlatform
            #endif
        }

        let remotePath = remoteConfigPath(hermesHome: profile.hermesHome, profileName: profileName)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-config-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await active.fetch(remotePath: remotePath, to: tmpURL)
        } catch let error as SSHTransportError {
            if case let .transferFailed(message) = error,
               message.lowercased().contains("no such file") {
                throw HermesConfigReaderError.notFound(path: remotePath)
            }
            throw HermesConfigReaderError.readFailed(error.message)
        } catch {
            throw HermesConfigReaderError.readFailed(error.localizedDescription)
        }

        do {
            return try String(contentsOf: tmpURL, encoding: .utf8)
        } catch {
            throw HermesConfigReaderError.readFailed(error.localizedDescription)
        }
    }
}
