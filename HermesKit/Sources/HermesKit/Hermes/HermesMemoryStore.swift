import Foundation

/// The two built-in memory files the Hermes agent manages with its `memory`
/// tool. Talaria edits their raw text directly on disk (local or over SSH) —
/// there is no dashboard route for their contents.
public enum HermesMemoryFile: String, Sendable, CaseIterable, Identifiable {
    case memory
    case user

    public var id: String { rawValue }

    public var fileName: String {
        switch self {
        case .memory: return "MEMORY.md"
        case .user: return "USER.md"
        }
    }

    /// The agent's soft character budget for this file, matching Hermes'
    /// `MemoryTool` defaults (`memory_char_limit=2200`, `user_char_limit=1375`).
    /// Only a display hint here — the editor warns past the cap but still saves;
    /// the agent itself enforces it at write time.
    public var charCap: Int {
        switch self {
        case .memory: return 2200
        case .user: return 1375
        }
    }
}

/// Memory-specific paths over the unified ``HermesFileStore``. Mirrors
/// ``HermesSoulReader``/``HermesConfigReader`` path conventions: files live at
/// `<HERMES_HOME>/memories/{MEMORY.md,USER.md}`, under `profiles/<name>/` for a
/// named profile. A missing file reads as empty (a fresh install legitimately
/// has none); the first save creates it.
public enum HermesMemoryStore {
    /// Path of a memory file relative to its Hermes home:
    /// `memories/MEMORY.md` for the default profile,
    /// `profiles/<name>/memories/MEMORY.md` otherwise.
    public static func relativePath(profileName: String, file: HermesMemoryFile) -> String {
        if profileName == HermesProfiles.defaultProfileName {
            return "memories/\(file.fileName)"
        }
        return "profiles/\(profileName)/memories/\(file.fileName)"
    }

    public static func read(
        profile: ServerProfile,
        profileName: String,
        file: HermesMemoryFile,
        transfer: RemoteSnapshotTransfer? = nil
    ) async throws -> String {
        do {
            return try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: relativePath(profileName: profileName, file: file)),
                transfer: transfer
            )
        } catch HermesFileStoreError.notFound {
            // No memory file yet (fresh install / never written): show an empty
            // editor; saving creates it.
            return ""
        }
    }

    public static func write(
        _ content: String,
        profile: ServerProfile,
        profileName: String,
        file: HermesMemoryFile,
        transfer: RemoteSnapshotTransfer? = nil
    ) async throws {
        try await HermesFileStore.write(
            content,
            profile: profile,
            location: .profileRelative(tail: relativePath(profileName: profileName, file: file)),
            transfer: transfer
        )
    }
}
