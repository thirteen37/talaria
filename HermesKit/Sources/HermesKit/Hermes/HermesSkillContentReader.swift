import Foundation

public enum HermesSkillContentError: Error, Equatable, Sendable, LocalizedError {
    case notFound(path: String)
    case readFailed(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .notFound(let path):
            return "No SKILL.md found at \(path)."
        case .readFailed(let detail):
            return "Couldn't read the skill: \(detail)"
        case .unsupportedPlatform:
            return "Reading a remote profile's skill requires the macOS host."
        }
    }
}

/// Reads a skill's `SKILL.md` text from a profile's skills directory — locally
/// or over SSH via an injected ``RemoteSnapshotTransfer`` — so the Sync tab can
/// show a side-by-side comparison of the default profile's skill against a named
/// profile's. Mirrors ``HermesConfigReader`` (the Hub's *latest* content isn't
/// fetchable — the index is metadata-only — so the only two comparable sides are
/// the two profiles' installed copies).
public enum HermesSkillContentReader {
    /// Path of a skill's `SKILL.md` relative to the **Hermes home**. Skills are
    /// stored under their category folder, so the leaf is
    /// `skills/<category>/<name>/SKILL.md` (or `skills/<name>/SKILL.md` when the
    /// skill is uncategorized). The default profile reads from the home root;
    /// every named profile reads from `profiles/<profile>/…`.
    public static func skillRelativePath(profileName: String, skillName: String, category: String?) -> String {
        let folder = category.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let tail = folder.isEmpty
            ? "skills/\(skillName)/SKILL.md"
            : "skills/\(folder)/\(skillName)/SKILL.md"
        if profileName == HermesProfiles.defaultProfileName {
            return tail
        }
        return "profiles/\(profileName)/\(tail)"
    }

    public static func read(
        profile: ServerProfile,
        profileName: String,
        skillName: String,
        category: String?,
        transfer: RemoteSnapshotTransfer? = nil
    ) async throws -> String {
        do {
            return try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: skillRelativePath(profileName: profileName, skillName: skillName, category: category)),
                transfer: transfer
            )
        } catch let error as HermesFileStoreError {
            throw mapError(error)
        }
    }

    private static func mapError(_ error: HermesFileStoreError) -> HermesSkillContentError {
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
