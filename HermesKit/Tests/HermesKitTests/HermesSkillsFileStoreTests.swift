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

    // MARK: - skillMarkdownTail

    @Test
    func skillMarkdownTailWithoutCategory() {
        #expect(HermesSkillsFileStore.skillMarkdownTail(category: nil, name: "cmux") == "skills/cmux/SKILL.md")
        #expect(HermesSkillsFileStore.skillMarkdownTail(category: "", name: "cmux") == "skills/cmux/SKILL.md")
    }

    @Test
    func skillMarkdownTailWithCategory() {
        #expect(
            HermesSkillsFileStore.skillMarkdownTail(category: "creative", name: "pixel-art")
                == "skills/creative/pixel-art/SKILL.md"
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

    // MARK: - remoteForceDeleteCommand

    @Test
    func remoteCommandForDefaultHome() throws {
        let cmd = try HermesSkillsFileStore.remoteForceDeleteCommand(hermesHome: nil, category: nil, name: "cmux")
        #expect(cmd == "rm -rf -- $HOME/'.hermes/skills/cmux'")
    }

    @Test
    func remoteCommandWithCategoryAndAbsoluteHome() throws {
        let cmd = try HermesSkillsFileStore.remoteForceDeleteCommand(
            hermesHome: "/opt/hermes", category: "creative", name: "pixel-art"
        )
        #expect(cmd == "rm -rf -- '/opt/hermes/skills/creative/pixel-art'")
    }

    @Test
    func remoteCommandWithTildeHome() throws {
        let cmd = try HermesSkillsFileStore.remoteForceDeleteCommand(
            hermesHome: "~/custom", category: nil, name: "cmux"
        )
        #expect(cmd == "rm -rf -- $HOME/'custom/skills/cmux'")
    }

    @Test
    func remoteCommandRejectsTraversalName() {
        #expect(throws: HermesSkillsFileStore.RemoteForceDeleteError.unsafeName) {
            try HermesSkillsFileStore.remoteForceDeleteCommand(hermesHome: nil, category: nil, name: "../etc")
        }
    }

    @Test
    func remoteCommandRejectsUnsafeCategory() {
        #expect(throws: HermesSkillsFileStore.RemoteForceDeleteError.unsafeCategory) {
            try HermesSkillsFileStore.remoteForceDeleteCommand(hermesHome: nil, category: "a/b", name: "cmux")
        }
    }

    @Test
    func remoteCommandRejectsTraversalInHome() {
        #expect(throws: HermesSkillsFileStore.RemoteForceDeleteError.unsafePath) {
            try HermesSkillsFileStore.remoteForceDeleteCommand(hermesHome: "~/../evil", category: nil, name: "cmux")
        }
    }

    // MARK: - forceDelete happy paths

    @Test
    func deletesSkillDirectory() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)

        try HermesSkillsFileStore.forceDelete(skillsRoot: root, category: nil, name: "cmux")
        #expect(FileManager.default.fileExists(atPath: skill.path) == false)
    }

    @Test
    func deletesCategorizedSkillDirectory() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent("creative/pixel-art", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)

        try HermesSkillsFileStore.forceDelete(skillsRoot: root, category: "creative", name: "pixel-art")
        #expect(FileManager.default.fileExists(atPath: skill.path) == false)
    }

    // MARK: - forceDelete refusals

    @Test
    func throwsNotFoundForMissingSkill() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: HermesSkillsFileStore.ForceDeleteError.notFound) {
            try HermesSkillsFileStore.forceDelete(skillsRoot: root, category: nil, name: "ghost")
        }
    }

    @Test
    func traversalNameIsRefusedAndSiblingSurvives() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A sibling *outside* the root that a traversal name would target.
        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("victim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        #expect(throws: (any Error).self) {
            try HermesSkillsFileStore.forceDelete(
                skillsRoot: root, category: nil, name: "../\(sibling.lastPathComponent)"
            )
        }
        #expect(FileManager.default.fileExists(atPath: sibling.path) == true)
    }

    @Test
    func symlinkedCategoryIsRefusedAndOutsideSurvives() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real directory OUTSIDE the root, holding a "victim" skill dir.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let victim = outside.appendingPathComponent("pixel-art", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        // An *intermediate* symlinked category inside the root pointing outside.
        let categoryLink = root.appendingPathComponent("creative", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: categoryLink, withDestinationURL: outside)

        // category "creative" resolves to `outside`, so the delete would escape.
        #expect(throws: (any Error).self) {
            try HermesSkillsFileStore.forceDelete(skillsRoot: root, category: "creative", name: "pixel-art")
        }
        #expect(FileManager.default.fileExists(atPath: victim.path) == true)
    }

    @Test
    func symlinkedSkillIsRefusedAndTargetSurvives() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Real directory outside the root, and a symlink to it inside the root.
        let target = root.deletingLastPathComponent()
            .appendingPathComponent("target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let link = root.appendingPathComponent("linkskill", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: HermesSkillsFileStore.ForceDeleteError.isSymlink) {
            try HermesSkillsFileStore.forceDelete(skillsRoot: root, category: nil, name: "linkskill")
        }
        #expect(FileManager.default.fileExists(atPath: target.path) == true)
    }
}
