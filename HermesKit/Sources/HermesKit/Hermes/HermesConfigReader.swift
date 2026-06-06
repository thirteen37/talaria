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
        do {
            return try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: configRelativePath(profileName: profileName)),
                transfer: transfer
            )
        } catch let error as HermesFileStoreError {
            throw mapError(error)
        }
    }

    private static func mapError(_ error: HermesFileStoreError) -> HermesConfigReaderError {
        switch error {
        case .notFound(let path):
            return .notFound(path: path)
        case .readFailed(let detail), .writeFailed(let detail):
            return .readFailed(detail)
        case .transferUnavailable:
            return .unsupportedPlatform
        }
    }
}
