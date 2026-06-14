import Crypto
import Foundation

public enum BundledSkillsResyncAction: String, Codable, Equatable, Sendable, CaseIterable {
    case add
    case update
    case skipUnchanged
    case skipModified
    case skipUnknown
    case skipDeleted
}

public struct BundledSkillsResyncItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }

    public let name: String
    public let category: String?
    public let path: String
    public let action: BundledSkillsResyncAction
    public let reason: String
    public let currentHash: String?
    public let sourceHash: String
    public let sourceCommit: String?

    public init(
        name: String,
        category: String?,
        path: String,
        action: BundledSkillsResyncAction,
        reason: String,
        currentHash: String?,
        sourceHash: String,
        sourceCommit: String?
    ) {
        self.name = name
        self.category = category
        self.path = path
        self.action = action
        self.reason = reason
        self.currentHash = currentHash
        self.sourceHash = sourceHash
        self.sourceCommit = sourceCommit
    }
}

public struct BundledSkillsResyncPlan: Codable, Equatable, Sendable {
    public let sourceRoot: URL
    public let skillsRoot: URL
    public let sourceCommit: String?
    public let items: [BundledSkillsResyncItem]

    public init(sourceRoot: URL, skillsRoot: URL, sourceCommit: String?, items: [BundledSkillsResyncItem]) {
        self.sourceRoot = sourceRoot
        self.skillsRoot = skillsRoot
        self.sourceCommit = sourceCommit
        self.items = items
    }

    public func count(_ action: BundledSkillsResyncAction) -> Int {
        items.filter { $0.action == action }.count
    }
}

public struct BundledSkillsResyncResult: Equatable, Sendable {
    public let added: [String]
    public let updated: [String]
    public let skipped: [String]
    public let sourceCommit: String?

    public init(added: [String], updated: [String], skipped: [String], sourceCommit: String?) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.sourceCommit = sourceCommit
    }
}

public enum BundledSkillsResyncError: Error, Equatable, Sendable, LocalizedError {
    case sourceUnavailable(String)
    case sourceNotGitRepo(String)
    case unsafeRelativePath(String)
    case planStale(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let path):
            return "Hermes source skills were not found at \(path)."
        case .sourceNotGitRepo(let path):
            return "Hermes source checkout is not a git repository: \(path)."
        case .unsafeRelativePath(let path):
            return "Refusing to resync unsafe skill path: \(path)."
        case .planStale(let path):
            return "The resync preview is stale for \(path). Refresh the preview and try again."
        }
    }
}

public protocol BundledSkillsHistoryChecking: Sendable {
    func hasHistoricalHash(
        _ hash: String,
        relativePath: String,
        sourceRoot: URL,
        fileManager: FileManager
    ) throws -> Bool
}

public struct GitBundledSkillsHistoryChecker: BundledSkillsHistoryChecking {
    public init() {}

    public func hasHistoricalHash(
        _ hash: String,
        relativePath: String,
        sourceRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
#if os(macOS)
        let repoRoot = sourceRoot.deletingLastPathComponent()
        let pathInRepo = sourceRoot.lastPathComponent + "/" + relativePath
        let commits = try Self.git(repoRoot: repoRoot, arguments: ["log", "--format=%H", "--", pathInRepo])
            .split(separator: "\n")
            .map(String.init)
        for commit in commits {
            if try Self.directoryHashInGitCommit(repoRoot: repoRoot, commit: commit, pathInRepo: pathInRepo) == hash {
                return true
            }
        }
#endif
        return false
    }

#if os(macOS)
    private static func git(repoRoot: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func gitData(repoRoot: URL, arguments: [String]) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }

    private static func directoryHashInGitCommit(repoRoot: URL, commit: String, pathInRepo: String) throws -> String? {
        guard let listData = try gitData(
            repoRoot: repoRoot,
            arguments: ["ls-tree", "-rz", "-r", commit, "--", pathInRepo]
        ), !listData.isEmpty else {
            return nil
        }
        var fileEntries: [(relative: String, blob: String)] = []
        for raw in listData.split(separator: 0) {
            guard let tab = raw.firstIndex(of: 9) else { continue }
            let header = raw[..<tab]
            let pathBytes = raw[raw.index(after: tab)...]
            let headerParts = String(decoding: header, as: UTF8.self).split(separator: " ")
            guard headerParts.count >= 3, headerParts[1] == "blob" else { continue }
            let fullPath = String(decoding: pathBytes, as: UTF8.self)
            let prefix = pathInRepo + "/"
            guard fullPath.hasPrefix(prefix) else { continue }
            fileEntries.append((String(fullPath.dropFirst(prefix.count)), String(headerParts[2])))
        }
        guard !fileEntries.isEmpty else { return nil }
        var hasher = SHA256()
        for entry in fileEntries.sorted(by: { $0.relative < $1.relative }) {
            guard let blob = try gitData(repoRoot: repoRoot, arguments: ["cat-file", "blob", entry.blob]) else {
                return nil
            }
            hasher.update(data: Data(entry.relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: blob)
            hasher.update(data: Data([0]))
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }
#endif
}

public struct BundledSkillsResyncService {
    public let sourceRoot: URL
    public let skillsRoot: URL
    public let historyChecker: any BundledSkillsHistoryChecking
    public let fileManager: FileManager

    public init(
        sourceRoot: URL = URL(
            fileURLWithPath: ("~/.hermes/hermes-agent/skills" as NSString).expandingTildeInPath,
            isDirectory: true
        ),
        skillsRoot: URL = HermesSkillsFileStore.localSkillsRoot(hermesHome: nil),
        historyChecker: any BundledSkillsHistoryChecking = GitBundledSkillsHistoryChecker(),
        fileManager: FileManager = .default
    ) {
        self.sourceRoot = URL(fileURLWithPath: (sourceRoot.path as NSString).expandingTildeInPath, isDirectory: true)
        self.skillsRoot = skillsRoot
        self.historyChecker = historyChecker
        self.fileManager = fileManager
    }

    public func preview() throws -> BundledSkillsResyncPlan {
        guard fileManager.fileExists(atPath: sourceRoot.path) else {
            throw BundledSkillsResyncError.sourceUnavailable(sourceRoot.path)
        }
        let sourceCommit = try currentSourceCommit()
        let sourceSkills = try discoverSkills(in: sourceRoot)
        let talariaManifest = try readTalariaManifest()
        let hermesManifest = try readHermesManifest()

        let talariaTracked = Set(talariaManifest.entries.keys)
        let sourceNames = Dictionary(uniqueKeysWithValues: sourceSkills.map { ($0.path, $0.name) })
        var items: [BundledSkillsResyncItem] = []

        for source in sourceSkills {
            let dest = destinationURL(for: source.path)
            let sourceHash = try Self.sha256DirectoryHash(source.url, fileManager: fileManager)
            let currentSHA = try directoryHashIfPresent(dest, algorithm: .sha256)
            let currentMD5 = try directoryHashIfPresent(dest, algorithm: .md5)
            let talariaBaseline = talariaManifest.entries[source.path]
            let hermesBaseline = hermesManifest[source.name] ?? hermesManifest[source.url.lastPathComponent]
            let tracked = talariaBaseline != nil || hermesBaseline != nil

            let action: BundledSkillsResyncAction
            let reason: String

            if let currentSHA {
                if currentSHA == sourceHash {
                    action = .skipUnchanged
                    reason = "Already matches the upstream skill."
                } else if talariaBaseline == currentSHA {
                    action = .update
                    reason = "Local copy matches the Talaria bundled baseline."
                } else if let currentMD5, hermesBaseline == currentMD5 {
                    action = .update
                    reason = "Local copy matches Hermes' bundled baseline."
                } else if tracked, try historyChecker.hasHistoricalHash(
                    currentSHA,
                    relativePath: source.path,
                    sourceRoot: sourceRoot,
                    fileManager: fileManager
                ) {
                    action = .update
                    reason = "Local copy matches a historical upstream version."
                } else if tracked {
                    action = .skipModified
                    reason = "Local copy differs from every trusted bundled baseline."
                } else {
                    action = .skipUnknown
                    reason = "A skill already exists at this path, but Talaria cannot prove it is an unmodified bundled copy."
                }
            } else if tracked {
                action = .skipDeleted
                reason = "This tracked built-in skill was deleted locally, so it will be left absent."
            } else {
                action = .add
                reason = "Missing locally and not previously tracked as deleted."
            }

            items.append(BundledSkillsResyncItem(
                name: source.name,
                category: source.category,
                path: source.path,
                action: action,
                reason: reason,
                currentHash: currentSHA,
                sourceHash: sourceHash,
                sourceCommit: action == .add || action == .update ? sourceCommit : nil
            ))
        }

        for path in talariaTracked.subtracting(sourceNames.keys).sorted() {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            items.append(BundledSkillsResyncItem(
                name: name,
                category: Self.category(from: path),
                path: path,
                action: .skipDeleted,
                reason: "This tracked built-in skill is no longer present upstream.",
                currentHash: try directoryHashIfPresent(destinationURL(for: path), algorithm: .sha256),
                sourceHash: talariaManifest.entries[path] ?? "",
                sourceCommit: nil
            ))
        }

        return BundledSkillsResyncPlan(
            sourceRoot: sourceRoot,
            skillsRoot: skillsRoot,
            sourceCommit: sourceCommit,
            items: items.sorted { $0.path < $1.path }
        )
    }

    public func apply(_ plan: BundledSkillsResyncPlan) throws -> BundledSkillsResyncResult {
        var added: [String] = []
        var updated: [String] = []
        var skipped: [String] = []
        var manifest = try readTalariaManifest().entries

        for item in plan.items {
            let source = sourceURL(for: item.path)
            let dest = destinationURL(for: item.path)
            switch item.action {
            case .add:
                guard !fileManager.fileExists(atPath: dest.path) else {
                    throw BundledSkillsResyncError.planStale("\(item.path): destination appeared")
                }
                let currentSourceHash = try Self.sha256DirectoryHash(source, fileManager: fileManager)
                guard currentSourceHash == item.sourceHash else {
                    throw BundledSkillsResyncError.planStale("\(item.path): source changed from \(item.sourceHash) to \(currentSourceHash)")
                }
                try copySkill(from: source, to: dest)
                manifest[item.path] = item.sourceHash
                added.append(item.path)
            case .update:
                guard try directoryHashIfPresent(dest, algorithm: .sha256) == item.currentHash else {
                    throw BundledSkillsResyncError.planStale("\(item.path): local changed")
                }
                let currentSourceHash = try Self.sha256DirectoryHash(source, fileManager: fileManager)
                guard currentSourceHash == item.sourceHash else {
                    throw BundledSkillsResyncError.planStale("\(item.path): source changed from \(item.sourceHash) to \(currentSourceHash)")
                }
                try replaceSkill(from: source, to: dest)
                manifest[item.path] = item.sourceHash
                updated.append(item.path)
            case .skipUnchanged:
                manifest[item.path] = item.sourceHash
                skipped.append(item.path)
            case .skipDeleted:
                if !item.sourceHash.isEmpty {
                    manifest[item.path] = item.sourceHash
                }
                skipped.append(item.path)
            case .skipModified:
                manifest[item.path] = manifest[item.path] ?? item.sourceHash
                skipped.append(item.path)
            case .skipUnknown:
                manifest.removeValue(forKey: item.path)
                skipped.append(item.path)
            }
        }

        try writeTalariaManifest(entries: manifest, sourceCommit: plan.sourceCommit)
        return BundledSkillsResyncResult(
            added: added,
            updated: updated,
            skipped: skipped,
            sourceCommit: plan.sourceCommit
        )
    }

    private struct SourceSkill {
        let name: String
        let category: String?
        let path: String
        let url: URL
    }

    private enum HashAlgorithm {
        case sha256
        case md5
    }

    private struct TalariaManifest {
        var sourceCommit: String?
        var entries: [String: String]
    }

    private func discoverSkills(in root: URL) throws -> [SourceSkill] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var skills: [SourceSkill] = []
        for case let skillMD as URL in enumerator where skillMD.lastPathComponent == "SKILL.md" {
            let skillDir = skillMD.deletingLastPathComponent()
            let rel = try relativePath(skillDir, under: root)
            let data = (try? String(contentsOf: skillMD, encoding: .utf8)) ?? ""
            let name = HermesSkillsFileStore.frontmatterName(data) ?? skillDir.lastPathComponent
            skills.append(SourceSkill(
                name: name,
                category: Self.category(from: rel),
                path: rel,
                url: skillDir
            ))
        }
        return skills.sorted { $0.path < $1.path }
    }

    private func currentSourceCommit() throws -> String? {
#if os(macOS)
        let repoRoot = sourceRoot.deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path, "rev-parse", "HEAD"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BundledSkillsResyncError.sourceNotGitRepo(repoRoot.path)
        }
        let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
#else
        return nil
#endif
    }

    private func destinationURL(for relativePath: String) -> URL {
        pathURL(root: skillsRoot, relativePath: relativePath)
    }

    private func sourceURL(for relativePath: String) -> URL {
        pathURL(root: sourceRoot, relativePath: relativePath)
    }

    private func pathURL(root: URL, relativePath: String) -> URL {
        var url = root
        for component in relativePath.split(separator: "/").map(String.init) {
            url.appendPathComponent(component, isDirectory: true)
        }
        return url
    }

    private func relativePath(_ url: URL, under root: URL) throws -> String {
        let rel = url.standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        let parts = rel.split(separator: "/").map(String.init)
        guard !rel.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw BundledSkillsResyncError.unsafeRelativePath(rel)
        }
        return parts.joined(separator: "/")
    }

    private func directoryHashIfPresent(_ url: URL, algorithm: HashAlgorithm) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        switch algorithm {
        case .sha256:
            return try Self.sha256DirectoryHash(url, fileManager: fileManager)
        case .md5:
            return try Self.md5DirectoryHash(url, fileManager: fileManager)
        }
    }

    private static func sha256DirectoryHash(_ directory: URL, fileManager: FileManager) throws -> String {
        var hasher = SHA256()
        try updateDirectoryHash(directory, fileManager: fileManager) { data in
            hasher.update(data: data)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func md5DirectoryHash(_ directory: URL, fileManager: FileManager) throws -> String {
        var hasher = Insecure.MD5()
        try updateDirectoryHash(directory, fileManager: fileManager) { data in
            hasher.update(data: data)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func updateDirectoryHash(
        _ directory: URL,
        fileManager: FileManager,
        update: (Data) -> Void
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(url)
            }
        }
        let basePath = directory.standardizedFileURL.path
        for file in files.sorted(by: { $0.standardizedFileURL.path < $1.standardizedFileURL.path }) {
            let rel = file.standardizedFileURL.path.replacingOccurrences(of: basePath + "/", with: "")
            update(Data(rel.utf8))
            update(Data([0]))
            update(try Data(contentsOf: file))
            update(Data([0]))
        }
    }

    private func readHermesManifest() throws -> [String: String] {
        let url = skillsRoot.appendingPathComponent(".bundled_manifest", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let colon = trimmed.firstIndex(of: ":") {
                result[String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)] =
                    String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                result[trimmed] = ""
            }
        }
        return result
    }

    private func readTalariaManifest() throws -> TalariaManifest {
        let url = skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest", isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return TalariaManifest(sourceCommit: nil, entries: [:]) }
        let text = try String(contentsOf: url, encoding: .utf8)
        var sourceCommit: String?
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("# source_commit:") {
                sourceCommit = String(trimmed.dropFirst("# source_commit:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { entries[key] = value }
        }
        return TalariaManifest(sourceCommit: sourceCommit, entries: entries)
    }

    private func writeTalariaManifest(entries: [String: String], sourceCommit: String?) throws {
        try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let url = skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest", isDirectory: false)
        var lines: [String] = []
        lines.append("# Talaria managed built-in skills baseline. Do not edit by hand.")
        if let sourceCommit, !sourceCommit.isEmpty {
            lines.append("# source_commit: \(sourceCommit)")
        }
        for (path, hash) in entries.sorted(by: { $0.key < $1.key }) {
            lines.append("\(path):\(hash)")
        }
        lines.append("")
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    private func copySkill(from source: URL, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }

    private func replaceSkill(from source: URL, to destination: URL) throws {
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).talaria-resync-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try copySkill(from: source, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: destination.path), fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func category(from relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }
}

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

    // MARK: - Bundled manifest (Hermes `.bundled_manifest`)

    /// The set of skill names Hermes tracks in its `skills/.bundled_manifest`
    /// (one `name:hash` line per skill in v2, plain `name` in v1). Blank lines
    /// and `#` comment lines are ignored; the name is the text before the first
    /// `:` (or the whole line when there is no colon), whitespace-trimmed.
    public static func parseBundledManifestNames(_ text: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let name = line.firstIndex(of: ":").map { String(line[..<$0]) } ?? line
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { names.insert(trimmed) }
        }
        return names
    }

    /// Bundled-skill names Hermes tracks but whose files are not present on the
    /// active (non-archived) skills tree — i.e. genuinely absent (deleted or
    /// archived), so `hermes skills reset` can re-seed them. Excludes skills that
    /// are present but merely filtered out of the dashboard list. Sorted.
    public static func inactiveTrackedNames(tracked: Set<String>, present: Set<String>) -> [String] {
        tracked.subtracting(present).sorted()
    }

    /// Absolute path of a **remote** host's `skills/.bundled_manifest`, for the
    /// inactive-builtins read. Normalizes `hermesHome` via
    /// ``HermesHomePaths/relativePath(hermesHome:tail:)`` and prepends the
    /// caller-resolved remote `$HOME` (`homeDirectory`) for the home-relative
    /// case so the path is absolute (the read goes over SSH with no shell to
    /// expand `~`). An absolute `hermesHome` passes through; when `homeDirectory`
    /// is nil a `~`-prefixed best-effort path is returned.
    public static func bundledManifestRemotePath(hermesHome: String?, homeDirectory: String?) -> String {
        let rel = HermesHomePaths.relativePath(hermesHome: hermesHome, tail: "skills/.bundled_manifest")
        if rel.hasPrefix("/") { return rel }
        if let homeDirectory, !homeDirectory.isEmpty { return "\(homeDirectory)/\(rel)" }
        return "~/\(rel)"
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
        // `command` bypasses a shell function/alias named `rm` on the remote
        // login shell (notably zsh, which expands aliases non-interactively and
        // sources .zshenv for `ssh host '…'`).
        return "command rm -rf -- \(ShellQuoting.shellQuote(directory))"
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

    /// A `/bin/sh` command (host shell, local or remote) that prints the
    /// frontmatter `name:` line of every `SKILL.md` on the **active** skills
    /// tree — i.e. excluding the non-discoverable `.archive/`, `.curator_backups/`
    /// and `.hub/` subtrees. One batched `find … -exec grep` round trip; the
    /// caller passes the output to ``parsePresentSkillNames``. Used to tell which
    /// tracked built-ins are genuinely absent (restorable) versus present but
    /// merely filtered out of the dashboard offer list (environment/platform/
    /// disabled), which `hermes skills reset` cannot restore.
    public static func presentSkillNamesListingCommand(hermesHome: String?) throws -> String {
        let rel = HermesHomePaths.relativePath(hermesHome: hermesHome, tail: "skills")
        guard !rel.split(separator: "/").contains("..") else { throw RemoteForceDeleteError.unsafePath }
        let quoted = ShellQuoting.shellQuote(rel)
        let base = rel.hasPrefix("/") ? quoted : "\"$HOME\"/\(quoted)"
        return "command find \(base) -name SKILL.md -not -path '*/.archive/*' -not -path '*/.curator_backups/*' -not -path '*/.hub/*' -exec grep -h -m1 '^name:' {} + 2>/dev/null"
    }

    /// Parses ``presentSkillNamesListingCommand`` output (one `name: <value>`
    /// line per present skill) into the set of frontmatter names, stripping
    /// surrounding quotes. Tolerates blank lines, non-`name:` lines, and CRLF.
    public static func parsePresentSkillNames(_ output: String) -> Set<String> {
        var names: Set<String> = []
        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("name:") else { continue }
            var value = String(line.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { names.insert(value) }
        }
        return names
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
        // `command` bypasses a shell function/alias named `find` (see the rm
        // command for the remote zsh rationale).
        return "command find \(base) -mindepth 1 -maxdepth 1 -type d 2>/dev/null"
    }

    /// A `/bin/sh` command (host shell, local or remote) that lists EVERY
    /// `SKILL.md` under the skills root — used to locate an *inactive* built-in
    /// (one not in the dashboard list, e.g. archived under `.archive/`) whose
    /// category isn't known. `find` descends hidden dirs (so `.archive/` is
    /// included). `$HOME` is double-quoted; the relative part is shell-quoted.
    public static func skillMarkdownListingCommand(hermesHome: String?) throws -> String {
        let rel = HermesHomePaths.relativePath(hermesHome: hermesHome, tail: "skills")
        guard !rel.split(separator: "/").contains("..") else { throw RemoteForceDeleteError.unsafePath }
        let quoted = ShellQuoting.shellQuote(rel)
        let base = rel.hasPrefix("/") ? quoted : "\"$HOME\"/\(quoted)"
        // `command` bypasses a shell function/alias named `find` (see the rm/find
        // commands above for the remote zsh rationale).
        return "command find \(base) -name SKILL.md -type f 2>/dev/null"
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
