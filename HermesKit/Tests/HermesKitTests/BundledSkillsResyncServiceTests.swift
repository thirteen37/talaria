import Crypto
import Foundation
import Testing
@testable import HermesKit

@Suite
struct BundledSkillsResyncServiceTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-resync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(root: URL, path: String, name: String, body: String = "Body") throws -> URL {
        let dir = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = """
        ---
        name: \(name)
        description: Test skill
        ---
        # \(name)
        \(body)
        """
        try md.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeSourceRepo() throws -> (repo: URL, skills: URL) {
        let repo = try makeTempDir()
        let skills = repo.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try git(repo, ["init"])
        try git(repo, ["config", "user.email", "tests@example.invalid"])
        try git(repo, ["config", "user.name", "Tests"])
        return (repo, skills)
    }

    private func commit(_ repo: URL, message: String) throws {
        try git(repo, ["add", "."])
        try git(repo, ["commit", "-m", message])
    }

    private func git(_ repo: URL, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path] + args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func sha256(_ dir: URL) throws -> String {
        var hasher = SHA256()
        try updateHash(dir) { hasher.update(data: $0) }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private func md5(_ dir: URL) throws -> String {
        var hasher = Insecure.MD5()
        try updateHash(dir) { hasher.update(data: $0) }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private func updateHash(_ dir: URL, update: (Data) -> Void) throws {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(url)
            }
        }
        let basePath = dir.standardizedFileURL.path
        for file in files.sorted(by: { $0.standardizedFileURL.path < $1.standardizedFileURL.path }) {
            let rel = file.standardizedFileURL.path.replacingOccurrences(of: basePath + "/", with: "")
            update(Data(rel.utf8))
            update(Data([0]))
            update(try Data(contentsOf: file))
            update(Data([0]))
        }
    }

    @Test
    func addsMissingUpstreamSkill() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        _ = try writeSkill(root: source, path: "software-development/plan", name: "plan")
        try commit(repo, message: "seed")

        let service = BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot)
        let plan = try service.preview()
        #expect(plan.items.map(\.action) == [.add])

        let result = try service.apply(plan)
        #expect(result.added == ["software-development/plan"])
        #expect(FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent("software-development/plan/SKILL.md").path))
    }

    @Test
    func updatesSkillMatchingTalariaManifestBaseline() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        let local = try writeSkill(root: skillsRoot, path: "devops/worker", name: "worker", body: "old")
        let oldHash = try sha256(local)
        _ = try writeSkill(root: source, path: "devops/worker", name: "worker", body: "new")
        try commit(repo, message: "source")
        try "devops/worker:\(oldHash)\n".write(
            to: skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest"),
            atomically: true,
            encoding: .utf8
        )

        let service = BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot)
        let plan = try service.preview()
        #expect(plan.items.first?.action == .update)
        _ = try service.apply(plan)

        let text = try String(contentsOf: local.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(text.contains("new"))
    }

    @Test
    func updatesSkillMatchingHermesBundledManifest() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        let local = try writeSkill(root: skillsRoot, path: "github/issues", name: "github-issues", body: "old")
        _ = try writeSkill(root: source, path: "github/issues", name: "github-issues", body: "new")
        try commit(repo, message: "source")
        let hermesManifest = "github-issues:\(try md5(local))\n"
        try hermesManifest.write(
            to: skillsRoot.appendingPathComponent(".bundled_manifest"),
            atomically: true,
            encoding: .utf8
        )

        let service = BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot)
        let plan = try service.preview()
        #expect(plan.items.first?.action == .update)
    }

    @Test
    func updatesSkillMatchingHistoricalUpstreamCommitWhenTracked() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        let sourceV1 = try writeSkill(root: source, path: "software-development/debugging", name: "debugging", body: "v1")
        try commit(repo, message: "v1")
        _ = try writeSkill(root: skillsRoot, path: "software-development/debugging", name: "debugging", body: "v1")
        let v1Hash = try sha256(sourceV1)
        _ = try writeSkill(root: source, path: "software-development/debugging", name: "debugging", body: "v2")
        try commit(repo, message: "v2")
        try "software-development/debugging:0000\n".write(
            to: skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try sha256(skillsRoot.appendingPathComponent("software-development/debugging")) == v1Hash)

        let service = BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot)
        let plan = try service.preview()
        #expect(plan.items.first?.action == .update)
        #expect(plan.items.first?.reason.contains("historical") == true)
    }

    @Test
    func historicalMatchIgnoresCommittedHiddenFiles() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        // The v1 source carries a committed dot-file; the on-disk copy is hashed
        // with `.skipsHiddenFiles`, so the git-derived historical hash must skip
        // hidden files too — otherwise the pristine v1 copy never matches and the
        // skill is wrongly classified `skipModified` instead of `update`.
        let sourceV1 = try writeSkill(root: source, path: "software-development/debugging", name: "debugging", body: "v1")
        try "*.log\n".write(to: sourceV1.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try commit(repo, message: "v1 with dotfile")
        _ = try writeSkill(root: skillsRoot, path: "software-development/debugging", name: "debugging", body: "v1")
        _ = try writeSkill(root: source, path: "software-development/debugging", name: "debugging", body: "v2")
        try commit(repo, message: "v2")
        try "software-development/debugging:0000\n".write(
            to: skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest"),
            atomically: true,
            encoding: .utf8
        )

        let plan = try BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot).preview()
        #expect(plan.items.first?.action == .update)
        #expect(plan.items.first?.reason.contains("historical") == true)
    }

    @Test
    func skipsLocallyModifiedTrackedSkill() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        _ = try writeSkill(root: source, path: "creative/art", name: "art", body: "source")
        try commit(repo, message: "source")
        _ = try writeSkill(root: skillsRoot, path: "creative/art", name: "art", body: "local edit")
        try "creative/art:baseline-that-does-not-match\n".write(
            to: skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest"),
            atomically: true,
            encoding: .utf8
        )

        let plan = try BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot).preview()
        #expect(plan.items.first?.action == .skipModified)
    }

    @Test
    func skipsUnknownExistingDestination() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        _ = try writeSkill(root: source, path: "creative/art", name: "art", body: "source")
        try commit(repo, message: "source")
        _ = try writeSkill(root: skillsRoot, path: "creative/art", name: "art", body: "custom")

        let plan = try BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot).preview()
        #expect(plan.items.first?.action == .skipUnknown)
    }

    @Test
    func leavesDeletedTrackedSkillAbsent() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        _ = try writeSkill(root: source, path: "research/arxiv", name: "arxiv")
        try commit(repo, message: "source")
        try "research/arxiv:tracked\n".write(
            to: skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest"),
            atomically: true,
            encoding: .utf8
        )

        let service = BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot)
        let plan = try service.preview()
        #expect(plan.items.first?.action == .skipDeleted)
        _ = try service.apply(plan)
        #expect(!FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent("research/arxiv").path))
    }

    @Test
    func writesOnlyTalariaManifestAndDoesNotModifyHermesManifest() throws {
        let (repo, source) = try makeSourceRepo()
        let skillsRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: skillsRoot)
        }
        _ = try writeSkill(root: source, path: "apple/notes", name: "notes")
        try commit(repo, message: "source")
        let hermesManifestURL = skillsRoot.appendingPathComponent(".bundled_manifest")
        let originalHermesManifest = "notes:abc123\n"
        try originalHermesManifest.write(to: hermesManifestURL, atomically: true, encoding: .utf8)

        let service = BundledSkillsResyncService(sourceRoot: source, skillsRoot: skillsRoot)
        _ = try service.apply(try service.preview())

        #expect(try String(contentsOf: hermesManifestURL, encoding: .utf8) == originalHermesManifest)
        #expect(FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent(".talaria_upstream_bundled_manifest").path))
    }
}
