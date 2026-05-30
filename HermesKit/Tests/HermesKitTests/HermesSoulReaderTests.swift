import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesSoulReaderTests {
    @Test
    func soulRelativePathForDefault() {
        #expect(HermesSoulReader.soulRelativePath(profileName: "default") == "SOUL.md")
    }

    @Test
    func soulRelativePathForNamedProfile() {
        #expect(HermesSoulReader.soulRelativePath(profileName: "work") == "profiles/work/SOUL.md")
    }

    @Test
    func remoteSoulPathDefaultsToHomeRelativeDotHermes() {
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: nil, profileName: "default") == ".hermes/SOUL.md")
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: nil, profileName: "work") == ".hermes/profiles/work/SOUL.md")
    }

    @Test
    func remoteSoulPathStripsTildeToRelative() {
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "~/.hermes", profileName: "default") == ".hermes/SOUL.md")
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "~", profileName: "default") == "SOUL.md")
    }

    @Test
    func remoteSoulPathKeepsAbsolutePath() {
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "/opt/hermes", profileName: "default") == "/opt/hermes/SOUL.md")
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "/opt/hermes/", profileName: "work") == "/opt/hermes/profiles/work/SOUL.md")
    }

    @Test
    func remoteSoulPathStripsDollarHomeToRelative() {
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "$HOME/.hermes", profileName: "default") == ".hermes/SOUL.md")
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "$HOME/.hermes", profileName: "work") == ".hermes/profiles/work/SOUL.md")
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "$HOME", profileName: "default") == "SOUL.md")
        #expect(HermesSoulReader.remoteSoulPath(hermesHome: "${HOME}/.hermes", profileName: "default") == ".hermes/SOUL.md")
    }

    @Test
    func readsLocalDefaultSoul() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Soul\n".write(to: dir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)
        let text = try await HermesSoulReader.read(profile: profile, profileName: "default")
        #expect(text.contains("# Soul"))
    }

    @Test
    func readsLocalNamedProfileSoul() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workDir = dir.appendingPathComponent("profiles/work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "You are direct.\n".write(to: workDir.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)
        let text = try await HermesSoulReader.read(profile: profile, profileName: "work")
        #expect(text.contains("You are direct."))
    }

    @Test
    func throwsNotFoundForMissingLocalSoul() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)
        await #expect(throws: HermesSoulReaderError.self) {
            _ = try await HermesSoulReader.read(profile: profile, profileName: "default")
        }
    }
}
