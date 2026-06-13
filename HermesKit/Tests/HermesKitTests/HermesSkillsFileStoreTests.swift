import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesSkillsFileStoreTests {
    /// Makes a unique temp directory to act as the skills root; caller removes it.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - localSkillsRoot

    @Test
    func localSkillsRootDefaultsToDotHermes() {
        let root = HermesSkillsFileStore.localSkillsRoot(hermesHome: nil)
        #expect(root.path.hasPrefix("/"))                 // tilde expanded to absolute
        #expect(root.path.hasSuffix("/.hermes/skills"))
    }

    @Test
    func localSkillsRootUsesConfiguredHome() {
        let root = HermesSkillsFileStore.localSkillsRoot(hermesHome: "/tmp/myhermes")
        #expect(root.path == "/tmp/myhermes/skills")
    }

    @Test
    func localSkillsRootExpandsTilde() {
        let root = HermesSkillsFileStore.localSkillsRoot(hermesHome: "~/custom")
        #expect(root.path.hasPrefix("/"))
        #expect(root.path.hasSuffix("/custom/skills"))
    }

    // MARK: - forceDeleteDirectory (delete a resolved dir)

    @Test
    func forceDeleteDirectoryRemovesADirUnderRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("creative/creative-ideation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try HermesSkillsFileStore.forceDeleteDirectory(dir, underSkillsRoot: root)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test
    func forceDeleteDirectoryRefusesOutsideRoot() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("victim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        #expect(throws: HermesSkillsFileStore.ForceDeleteError.outsideRoot) {
            try HermesSkillsFileStore.forceDeleteDirectory(outside, underSkillsRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path) == true)
    }

    @Test
    func forceDeleteDirectoryThrowsNotFoundForMissingDir() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: HermesSkillsFileStore.ForceDeleteError.notFound) {
            try HermesSkillsFileStore.forceDeleteDirectory(
                root.appendingPathComponent("ghost", isDirectory: true), underSkillsRoot: root
            )
        }
    }

    @Test
    func forceDeleteDirectoryRefusesSymlinkedLeaf() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real directory outside the root, and a symlink to it inside the root.
        let target = root.deletingLastPathComponent()
            .appendingPathComponent("target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let link = root.appendingPathComponent("linkskill", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: HermesSkillsFileStore.ForceDeleteError.isSymlink) {
            try HermesSkillsFileStore.forceDeleteDirectory(link, underSkillsRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: target.path) == true)
    }

    @Test
    func forceDeleteDirectoryRefusesViaSymlinkedParent() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real directory OUTSIDE the root, holding a "victim" skill dir, with an
        // intermediate symlinked category inside the root pointing at it.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let victim = outside.appendingPathComponent("pixel-art", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let categoryLink = root.appendingPathComponent("creative", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: categoryLink, withDestinationURL: outside)

        // <root>/creative/pixel-art resolves (via the symlink) to outside/pixel-art.
        #expect(throws: HermesSkillsFileStore.ForceDeleteError.outsideRoot) {
            try HermesSkillsFileStore.forceDeleteDirectory(
                categoryLink.appendingPathComponent("pixel-art", isDirectory: true), underSkillsRoot: root
            )
        }
        #expect(FileManager.default.fileExists(atPath: victim.path) == true)
    }

    // MARK: - remoteForceDeleteDirectoryCommand

    @Test
    func remoteDeleteDirectoryCommandQuotesAbsolutePath() throws {
        let cmd = try HermesSkillsFileStore.remoteForceDeleteDirectoryCommand(
            directory: "/home/u/.hermes/skills/creative/creative-ideation"
        )
        #expect(cmd == "rm -rf -- '/home/u/.hermes/skills/creative/creative-ideation'")
    }

    @Test
    func remoteDeleteDirectoryCommandRejectsUnsafeDirectories() {
        // Relative, traversal, and paths with no `skills` component are refused.
        for bad in ["relative/skills/foo", "/home/u/skills/../../etc", "/home/u/other/foo"] {
            #expect(throws: HermesSkillsFileStore.RemoteForceDeleteError.unsafePath) {
                try HermesSkillsFileStore.remoteForceDeleteDirectoryCommand(directory: bad)
            }
        }
    }

    // MARK: - frontmatterName

    @Test
    func frontmatterNameReadsTopLevelNameKey() {
        let md = """
        ---
        name: ideation
        description: Brainstorm
        ---
        # Body with a name: in it
        """
        #expect(HermesSkillsFileStore.frontmatterName(md) == "ideation")
    }

    @Test
    func frontmatterNameStripsQuotesAndIgnoresIndentedKeys() {
        let md = """
        ---
        meta:
          name: nested-should-be-ignored
        name: "pixel-art"
        ---
        body
        """
        #expect(HermesSkillsFileStore.frontmatterName(md) == "pixel-art")
    }

    @Test
    func frontmatterNameHandlesCRLF() {
        // MarkdownFrontmatter.split preserves CRLF, so the name value must not
        // keep a trailing \r (or it never matches the dashboard name).
        #expect(HermesSkillsFileStore.frontmatterName("---\r\nname: ideation\r\n---\r\n# Body\r\n") == "ideation")
        #expect(HermesSkillsFileStore.frontmatterName("---\r\nname: \"pixel-art\"\r\n---\r\n") == "pixel-art")
    }

    @Test
    func frontmatterNameNilWithoutFrontmatterOrName() {
        #expect(HermesSkillsFileStore.frontmatterName("# Just a heading\n") == nil)
        #expect(HermesSkillsFileStore.frontmatterName("---\ndescription: x\n---\nbody") == nil)
    }

    // MARK: - skillCandidateListingCommand

    @Test
    func listingCommandScopesToCategoryUnderHome() throws {
        let cmd = try HermesSkillsFileStore.skillCandidateListingCommand(hermesHome: nil, category: "creative")
        #expect(cmd == "find \"$HOME\"/'.hermes/skills/creative' -mindepth 1 -maxdepth 1 -type d 2>/dev/null")
    }

    @Test
    func listingCommandUncategorizedScansSkillsRoot() throws {
        let cmd = try HermesSkillsFileStore.skillCandidateListingCommand(hermesHome: "/opt/hermes", category: nil)
        #expect(cmd == "find '/opt/hermes/skills' -mindepth 1 -maxdepth 1 -type d 2>/dev/null")
    }

    @Test
    func listingCommandRejectsUnsafeCategory() {
        #expect(throws: HermesSkillsFileStore.RemoteForceDeleteError.unsafeCategory) {
            try HermesSkillsFileStore.skillCandidateListingCommand(hermesHome: nil, category: "../etc")
        }
    }

    // MARK: - parseDirectoryListing

    @Test
    func parseDirectoryListingTrimsAndDropsBlanks() {
        let output = "/home/u/.hermes/skills/creative/pixel-art\n/home/u/.hermes/skills/creative/creative-ideation\n\n"
        #expect(
            HermesSkillsFileStore.parseDirectoryListing(output) == [
                "/home/u/.hermes/skills/creative/pixel-art",
                "/home/u/.hermes/skills/creative/creative-ideation",
            ]
        )
    }

    // MARK: - remoteSkillPath (Publish pre-fill)

    @Test
    func remoteSkillPathPrependsResolvedHomeForTilde() {
        let path = HermesSkillsFileStore.remoteSkillPath(
            hermesHome: "~/.hermes", category: nil, name: "cmux", homeDirectory: "/home/u"
        )
        #expect(path == "/home/u/.hermes/skills/cmux")
    }

    @Test
    func remoteSkillPathExpandsDollarHomePrefix() {
        // `$HOME`/`${HOME}` are forms relativePath supports; they must resolve the
        // same as `~` (the bug: they previously fell through unexpanded).
        #expect(
            HermesSkillsFileStore.remoteSkillPath(
                hermesHome: "$HOME/.hermes", category: nil, name: "cmux", homeDirectory: "/home/u"
            ) == "/home/u/.hermes/skills/cmux"
        )
        #expect(
            HermesSkillsFileStore.remoteSkillPath(
                hermesHome: "${HOME}/custom", category: "creative", name: "pixel-art", homeDirectory: "/home/u"
            ) == "/home/u/custom/skills/creative/pixel-art"
        )
    }

    @Test
    func remoteSkillPathPassesAbsoluteHomeThrough() {
        let path = HermesSkillsFileStore.remoteSkillPath(
            hermesHome: "/opt/hermes", category: nil, name: "cmux", homeDirectory: "/home/u"
        )
        #expect(path == "/opt/hermes/skills/cmux")
    }

    @Test
    func remoteSkillPathFallsBackToTildeWhenHomeUnknown() {
        let path = HermesSkillsFileStore.remoteSkillPath(
            hermesHome: nil, category: nil, name: "cmux", homeDirectory: nil
        )
        #expect(path == "~/.hermes/skills/cmux")
    }

}
