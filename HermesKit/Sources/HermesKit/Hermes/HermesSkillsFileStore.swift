import Foundation

/// Direct-filesystem **force delete** of a skill directory — the one skills
/// operation Hermes' CLI can't do. `hermes skills uninstall` refuses builtins
/// and only knows hub-installed skills (`tools/skills_hub.py::uninstall_skill`),
/// and there is no other delete command. Local profiles only (there is no remote
/// delete transport — `RemoteSnapshotTransfer` is fetch/upload). The guard
/// mirrors hermes' own `_resolve_lock_install_path` rmtree boundary so a crafted
/// name or a symlinked skill folder can never escape the skills root.
public enum HermesSkillsFileStore {
    public enum ForceDeleteError: Error, Equatable, LocalizedError {
        /// Resolved path escapes the skills root.
        case outsideRoot
        /// Resolved path *is* the skills root (defensive; unreachable while a
        /// non-empty `name` is always appended).
        case isRoot
        /// Resolved leaf component doesn't equal the skill name (rejects
        /// embedded separators / `..` traversal).
        case nameMismatch
        /// The skill directory is a symlink — refuse rather than follow it out.
        case isSymlink
        /// Nothing exists at the resolved path.
        case notFound

        public var errorDescription: String? {
            switch self {
            case .outsideRoot:  return "Refusing to delete: the resolved path is outside the skills directory."
            case .isRoot:       return "Refusing to delete: the resolved path is the skills directory itself."
            case .nameMismatch: return "Refusing to delete: the resolved path does not match the skill name."
            case .isSymlink:    return "Refusing to delete a symlinked skill directory."
            case .notFound:     return "The skill directory does not exist."
            }
        }
    }

    /// The local skills root (`<hermesHome>/skills`, default `~/.hermes/skills`),
    /// with `~` expanded. Shared by force-delete and the Publish default path.
    public static func localSkillsRoot(hermesHome: String?) -> URL {
        let trimmed = hermesHome?.trimmingCharacters(in: .whitespaces)
        let homePath: String
        if let trimmed, !trimmed.isEmpty {
            homePath = (trimmed as NSString).expandingTildeInPath
        } else {
            homePath = ("~/.hermes" as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// The profile-relative path of a skill's `SKILL.md`
    /// (`skills/[<category>/]<name>/SKILL.md`), for `HermesFileStore`'s
    /// `.profileRelative` reads — which prepend the Hermes home via
    /// ``HermesHomePaths/relativePath(hermesHome:tail:)``. Used to preview a
    /// skill's source on local *and* remote profiles.
    public static func skillMarkdownTail(category: String?, name: String) -> String {
        var tail = "skills"
        if let category, !category.isEmpty {
            tail += "/\(category)"
        }
        return tail + "/\(name)/SKILL.md"
    }

    /// Validates and returns the directory a skill occupies under `skillsRoot`,
    /// refusing anything that escapes the root, equals it, doesn't end in `name`,
    /// or is a symlink. Standardizes `..`/`.` but deliberately does NOT resolve
    /// symlinks (so the leaf symlink check is meaningful); root and candidate are
    /// standardized identically so they share a path prefix.
    public static func resolvedSkillPath(
        skillsRoot: URL,
        category: String?,
        name: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = skillsRoot.standardizedFileURL
        var candidate = root
        if let category, !category.isEmpty {
            candidate.appendPathComponent(category, isDirectory: true)
        }
        candidate.appendPathComponent(name, isDirectory: true)
        candidate = candidate.standardizedFileURL

        guard candidate.lastPathComponent == name else { throw ForceDeleteError.nameMismatch }
        guard candidate.path != root.path else { throw ForceDeleteError.isRoot }
        guard candidate.path.hasPrefix(root.path + "/") else { throw ForceDeleteError.outsideRoot }

        let attrs = try? fileManager.attributesOfItem(atPath: candidate.path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw ForceDeleteError.isSymlink
        }
        return candidate
    }

    /// `resolvedSkillPath` then `removeItem`. Throws `.notFound` if absent.
    public static func forceDelete(
        skillsRoot: URL,
        category: String?,
        name: String,
        fileManager: FileManager = .default
    ) throws {
        let path = try resolvedSkillPath(
            skillsRoot: skillsRoot, category: category, name: name, fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: path.path) else { throw ForceDeleteError.notFound }
        try fileManager.removeItem(at: path)
    }

    // MARK: - Remote force-delete

    public enum RemoteForceDeleteError: Error, Equatable, LocalizedError {
        /// The skill `name` isn't a single safe path segment.
        case unsafeName
        /// The `category` isn't a single safe path segment.
        case unsafeCategory
        /// The resolved path contains a `..` component (e.g. a crafted
        /// `hermesHome`) and could escape the skills tree.
        case unsafePath

        public var errorDescription: String? {
            switch self {
            case .unsafeName:     return "Refusing to delete: unsafe skill name."
            case .unsafeCategory: return "Refusing to delete: unsafe skill category."
            case .unsafePath:     return "Refusing to delete: the resolved path escapes the skills directory."
            }
        }
    }

    /// Builds a `/bin/sh`-safe `rm -rf` command for a skill directory on a
    /// **remote** host's Hermes skills tree, for the host-shell delete path
    /// (there's no `FileManager` over SSH, and the admin runner only runs
    /// `hermes` subcommands). The local path uses ``forceDelete``'s stronger,
    /// symlink-aware guard; the remote shell can't `stat` the leaf, so this is a
    /// string guard: `name`/`category` must each be a single safe segment, and
    /// the resolved path must contain no `..`. The home base is `$HOME`-relative
    /// (so `~`/unset resolve on the remote side) or absolute, and is
    /// shell-quoted. Throws on unsafe input rather than emitting a dangerous
    /// command.
    public static func remoteForceDeleteCommand(
        hermesHome: String?,
        category: String?,
        name: String
    ) throws -> String {
        guard isSafePathSegment(name) else { throw RemoteForceDeleteError.unsafeName }
        if let category, !category.isEmpty, !isSafePathSegment(category) {
            throw RemoteForceDeleteError.unsafeCategory
        }
        var tail = "skills"
        if let category, !category.isEmpty { tail += "/\(category)" }
        tail += "/\(name)"
        let path = HermesHomePaths.relativePath(hermesHome: hermesHome, tail: tail)
        guard !path.split(separator: "/").contains("..") else { throw RemoteForceDeleteError.unsafePath }
        let quoted = ShellQuoting.shellQuote(path)
        // `relativePath` returns an absolute path for an absolute `hermesHome`,
        // else a path relative to the login home (which `$HOME` resolves to).
        return path.hasPrefix("/") ? "rm -rf -- \(quoted)" : "rm -rf -- $HOME/\(quoted)"
    }

    /// A single path segment safe to interpolate into a shell path: non-empty,
    /// not `.`/`..`, and only letters/digits/`.`/`-`/`_` (no separators or shell
    /// metacharacters).
    static func isSafePathSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
