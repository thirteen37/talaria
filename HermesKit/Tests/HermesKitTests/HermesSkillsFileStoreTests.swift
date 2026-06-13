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
