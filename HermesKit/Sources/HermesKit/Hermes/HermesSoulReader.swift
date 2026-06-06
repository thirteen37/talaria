import Foundation

public enum HermesSoulReaderError: Error, Equatable, Sendable, LocalizedError {
    case notFound(path: String)
    case readFailed(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No SOUL.md found at \(path)."
        case .readFailed(let detail):
            return "Couldn't read SOUL.md: \(detail)"
        case .unsupportedPlatform:
            return "Reading a remote profile's SOUL.md requires the macOS host."
        }
    }
}

/// Reads a profile's `SOUL.md` locally or through the same read-only remote
/// transfer used by the degraded config editor. Writes stay dashboard-only.
public enum HermesSoulReader {
    /// Path of a profile's SOUL.md relative to its Hermes home:
    /// `SOUL.md` for the default profile, `profiles/<name>/SOUL.md` otherwise.
    public static func soulRelativePath(profileName: String) -> String {
        if profileName == HermesProfiles.defaultProfileName {
            return "SOUL.md"
        }
        return "profiles/\(profileName)/SOUL.md"
    }

    public static func remoteSoulPath(hermesHome: String?, profileName: String) -> String {
        HermesHomePaths.relativePath(hermesHome: hermesHome, tail: soulRelativePath(profileName: profileName))
    }

    public static func read(
        profile: ServerProfile,
        profileName: String,
        transfer: RemoteSnapshotTransfer? = nil
    ) async throws -> String {
        do {
            return try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: soulRelativePath(profileName: profileName)),
                transfer: transfer
            )
        } catch let error as HermesFileStoreError {
            throw mapError(error)
        }
    }

    private static func mapError(_ error: HermesFileStoreError) -> HermesSoulReaderError {
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
