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
        /// The skill directory is a symlink — refuse rather than follow it out.
        case isSymlink
        /// Nothing exists at the resolved path.
        case notFound

        public var errorDescription: String? {
            switch self {
            case .outsideRoot: return "Refusing to delete: the resolved path is outside the skills directory."
            case .isSymlink:   return "Refusing to delete a symlinked skill directory."
            case .notFound:    return "The skill directory does not exist."
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

    // MARK: - Remote force-delete

    public enum RemoteForceDeleteError: Error, Equatable, LocalizedError {
        /// The `category` isn't a single safe path segment.
        case unsafeCategory
        /// The resolved path contains a `..` component (e.g. a crafted
        /// `hermesHome`) and could escape the skills tree.
        case unsafePath

        public var errorDescription: String? {
            switch self {
            case .unsafeCategory: return "Refusing to delete: unsafe skill category."
            case .unsafePath:     return "Refusing to delete: the resolved path escapes the skills directory."
            }
        }
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
        // Split on `Character.isNewline` (not the literal `"\n"`), which treats a
        // CRLF `\r\n` — preserved by `MarkdownFrontmatter.split` — as one line
        // break; splitting on `"\n"` would miss it (Swift makes `\r\n` one
        // grapheme) and never find the `name:` line in a CRLF document.
        for rawLine in parts.frontmatter.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard rawLine.hasPrefix("name:") else { continue }
            var value = rawLine.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines)
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
