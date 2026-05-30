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
        switch profile.kind {
        case .local:
            return try readLocal(profile: profile, profileName: profileName)
        case .ssh:
            return try await readRemote(profile: profile, profileName: profileName, transfer: transfer)
        }
    }

    private static func readLocal(profile: ServerProfile, profileName: String) throws -> String {
        let home = profile.hermesHome.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".hermes", isDirectory: true)
        let url = home.appendingPathComponent(soulRelativePath(profileName: profileName))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HermesSoulReaderError.notFound(path: url.path)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HermesSoulReaderError.readFailed(error.localizedDescription)
        }
    }

    private static func readRemote(
        profile: ServerProfile,
        profileName: String,
        transfer: RemoteSnapshotTransfer?
    ) async throws -> String {
        let active: RemoteSnapshotTransfer
        if let transfer {
            active = transfer
        } else {
            #if os(macOS)
            active = SFTPSubprocessTransfer(profile: profile)
            #else
            throw HermesSoulReaderError.unsupportedPlatform
            #endif
        }

        let remotePath = remoteSoulPath(hermesHome: profile.hermesHome, profileName: profileName)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-soul-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await active.fetch(remotePath: remotePath, to: tmpURL)
        } catch let error as SSHTransportError {
            if case let .transferFailed(message) = error,
               message.lowercased().contains("no such file") {
                throw HermesSoulReaderError.notFound(path: remotePath)
            }
            throw HermesSoulReaderError.readFailed(error.message)
        } catch {
            throw HermesSoulReaderError.readFailed(error.localizedDescription)
        }

        do {
            return try String(contentsOf: tmpURL, encoding: .utf8)
        } catch {
            throw HermesSoulReaderError.readFailed(error.localizedDescription)
        }
    }
}
