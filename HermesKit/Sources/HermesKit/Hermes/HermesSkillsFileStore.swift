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
    /// or is a symlink. `name`/`category` must each be a single safe path segment
    /// (no separators, `..`, or shell metacharacters), mirroring the remote path.
    /// Containment is checked against the **symlink-resolved** root and candidate
    /// *parent*, so neither an intermediate symlinked category (`<root>/<cat>` →
    /// `/elsewhere`) nor a symlinked root can escape; the leaf is left unresolved
    /// so a symlinked *skill folder* is detected and refused rather than followed.
    public static func resolvedSkillPath(
        skillsRoot: URL,
        category: String?,
        name: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isSafePathSegment(name) else { throw ForceDeleteError.nameMismatch }
        if let category, !category.isEmpty, !isSafePathSegment(category) {
            throw ForceDeleteError.outsideRoot
        }

        let root = skillsRoot.standardizedFileURL
        var candidate = root
        if let category, !category.isEmpty {
            candidate.appendPathComponent(category, isDirectory: true)
        }
        candidate.appendPathComponent(name, isDirectory: true)
        candidate = candidate.standardizedFileURL

        guard candidate.lastPathComponent == name else { throw ForceDeleteError.nameMismatch }
        guard candidate.path != root.path else { throw ForceDeleteError.isRoot }

        // Resolve symlinks in the root and the candidate's *parent* (catching an
        // intermediate symlinked category), but keep the leaf unresolved so the
        // leaf symlink check below stays meaningful. Both sides are resolved the
        // same way, so a symlinked root (e.g. /tmp → /private/tmp on macOS)
        // doesn't trip a false escape.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolvedCandidate = resolvedParent.appendingPathComponent(candidate.lastPathComponent)
        guard resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ForceDeleteError.outsideRoot
        }

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
        // else a path relative to the login home. `"$HOME"` is double-quoted so a
        // home containing whitespace/globs isn't word-split inside `rm -rf`.
        return path.hasPrefix("/") ? "rm -rf -- \(quoted)" : "rm -rf -- \"$HOME\"/\(quoted)"
    }

    /// The absolute path of a skill directory on a **remote** host, for the
    /// Publish sheet's pre-fill. Normalizes the profile's `hermesHome` —
    /// `~`/`$HOME`/`${HOME}` prefixes and absolute paths alike — via
    /// ``HermesHomePaths/relativePath(hermesHome:tail:)``, then prepends the
    /// caller-resolved remote `$HOME` (`homeDirectory`) for the home-relative
    /// case so `hermes skills publish` receives an absolute path (its arg goes
    /// through argv with no shell to expand `~`/`$HOME`). An absolute `hermesHome`
    /// passes through unchanged; when `homeDirectory` is nil the home-relative
    /// path is returned `~`-prefixed as a best-effort editable default.
    public static func remoteSkillPath(
        hermesHome: String?,
        category: String?,
        name: String,
        homeDirectory: String?
    ) -> String {
        var tail = "skills"
        if let category, !category.isEmpty { tail += "/\(category)" }
        tail += "/\(name)"
        let rel = HermesHomePaths.relativePath(hermesHome: hermesHome, tail: tail)
        if rel.hasPrefix("/") { return rel }
        if let homeDirectory, !homeDirectory.isEmpty { return "\(homeDirectory)/\(rel)" }
        return "~/\(rel)"
    }

    // MARK: - Delete a resolved directory

    /// Deletes an already-resolved skill `directory` (located by matching its
    /// `SKILL.md` frontmatter name), refusing anything that — symlink-resolved —
    /// isn't a real directory strictly under `root`, or whose leaf is a symlink.
    /// Use when the on-disk directory name differs from the dashboard `name`.
    public static func forceDeleteDirectory(
        _ directory: URL,
        underSkillsRoot root: URL,
        fileManager: FileManager = .default
    ) throws {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let dir = directory.standardizedFileURL
        let resolvedDir = dir.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(dir.lastPathComponent)
        guard resolvedDir.path.hasPrefix(resolvedRoot.path + "/") else { throw ForceDeleteError.outsideRoot }
        let attrs = try? fileManager.attributesOfItem(atPath: dir.path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw ForceDeleteError.isSymlink
        }
        guard fileManager.fileExists(atPath: dir.path) else { throw ForceDeleteError.notFound }
        try fileManager.removeItem(at: dir)
    }

    /// A `rm -rf` command for an already-resolved **remote** skill `directory`
    /// (absolute, from the listing under the skills root). Refuses a non-absolute
    /// path, any `..` component, or a path with no `skills` component (a coarse
    /// guard that it really is inside a Hermes skills tree), then shell-quotes it.
    public static func remoteForceDeleteDirectoryCommand(directory: String) throws -> String {
        let components = directory.split(separator: "/")
        guard directory.hasPrefix("/"),
              !components.contains(".."),
              components.contains("skills") else {
            throw RemoteForceDeleteError.unsafePath
        }
        return "rm -rf -- \(ShellQuoting.shellQuote(directory))"
    }

    // MARK: - Directory resolution by frontmatter name

    /// The top-level `name:` value from a `SKILL.md`'s YAML frontmatter, or nil
    /// when there's no frontmatter or no top-level `name`. Used to map a skill's
    /// dashboard `name` (which is this frontmatter value, *not* the directory
    /// name) back to its actual on-disk directory. Only a column-0 `name:` in the
    /// leading `---` block counts (indented/nested keys and body text are
    /// ignored); surrounding quotes are stripped.
    public static func frontmatterName(_ skillMarkdown: String) -> String? {
        guard let parts = MarkdownFrontmatter.split(skillMarkdown) else { return nil }
        for rawLine in parts.frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            guard rawLine.hasPrefix("name:") else { continue }
            var value = rawLine.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// A `/bin/sh` command (via the host shell, local or remote) that lists the
    /// immediate skill-directory candidates to inspect: the subdirectories of the
    /// skill's category (`<root>/skills/<category>`), or of the skills root for an
    /// uncategorized skill. The caller then reads each candidate's `SKILL.md` and
    /// matches ``frontmatterName`` to find the real directory — `<category>` comes
    /// from the on-disk path so it's reliable, unlike the frontmatter `name`.
    /// `$HOME` is double-quoted; the relative part is shell-quoted. Throws on an
    /// unsafe category segment.
    public static func skillCandidateListingCommand(hermesHome: String?, category: String?) throws -> String {
        if let category, !category.isEmpty, !isSafePathSegment(category) {
            throw RemoteForceDeleteError.unsafeCategory
        }
        var tail = "skills"
        if let category, !category.isEmpty { tail += "/\(category)" }
        let rel = HermesHomePaths.relativePath(hermesHome: hermesHome, tail: tail)
        guard !rel.split(separator: "/").contains("..") else { throw RemoteForceDeleteError.unsafePath }
        let quoted = ShellQuoting.shellQuote(rel)
        let base = rel.hasPrefix("/") ? quoted : "\"$HOME\"/\(quoted)"
        return "find \(base) -mindepth 1 -maxdepth 1 -type d 2>/dev/null"
    }

    /// Splits a directory-listing command's stdout into trimmed, non-empty
    /// absolute directory paths.
    public static func parseDirectoryListing(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A single path segment safe to interpolate into a shell path: non-empty,
    /// not `.`/`..`, and only letters/digits/`.`/`-`/`_` (no separators or shell
    /// metacharacters).
    static func isSafePathSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, segment != ".", segment != ".." else { return false }
        return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
