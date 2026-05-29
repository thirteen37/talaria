import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesConfigReaderTests {
    // MARK: - Path computation

    @Test
    func configRelativePathForDefault() {
        #expect(HermesConfigReader.configRelativePath(profileName: "default") == "config.yaml")
    }

    @Test
    func configRelativePathForNamedProfile() {
        #expect(HermesConfigReader.configRelativePath(profileName: "work") == "profiles/work/config.yaml")
    }

    @Test
    func remoteConfigPathDefaultsToHomeRelativeDotHermes() {
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: nil, profileName: "default") == ".hermes/config.yaml")
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: nil, profileName: "work") == ".hermes/profiles/work/config.yaml")
    }

    @Test
    func remoteConfigPathStripsTildeToRelative() {
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "~/.hermes", profileName: "default") == ".hermes/config.yaml")
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "~", profileName: "default") == "config.yaml")
    }

    @Test
    func remoteConfigPathKeepsAbsolutePath() {
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "/opt/hermes", profileName: "default") == "/opt/hermes/config.yaml")
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "/opt/hermes/", profileName: "work") == "/opt/hermes/profiles/work/config.yaml")
    }

    @Test
    func remoteConfigPathStripsDollarHomeToRelative() {
        // SFTP performs no shell expansion, so a `$HOME`-prefixed home (a form
        // `RemoteSnapshot.remoteStateDBPath` supports for the shell-run backup)
        // must become a home-relative path, exactly like `~`.
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "$HOME/.hermes", profileName: "default") == ".hermes/config.yaml")
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "$HOME/.hermes", profileName: "work") == ".hermes/profiles/work/config.yaml")
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "$HOME", profileName: "default") == "config.yaml")
        #expect(HermesConfigReader.remoteConfigPath(hermesHome: "${HOME}/.hermes", profileName: "default") == ".hermes/config.yaml")
    }

    // MARK: - Local read

    @Test
    func readsLocalDefaultConfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "log_level: info\n".write(to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)
        let text = try await HermesConfigReader.read(profile: profile, profileName: "default")
        #expect(text.contains("log_level: info"))
    }

    @Test
    func readsLocalNamedProfileConfig() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workDir = dir.appendingPathComponent("profiles/work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "model:\n  default: sonnet\n".write(to: workDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)
        let text = try await HermesConfigReader.read(profile: profile, profileName: "work")
        #expect(text.contains("default: sonnet"))
    }

    @Test
    func throwsNotFoundForMissingLocalConfig() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profile = ServerProfile(name: "Local", kind: .local, hermesHome: dir.path)
        await #expect(throws: HermesConfigReaderError.self) {
            _ = try await HermesConfigReader.read(profile: profile, profileName: "default")
        }
    }
}
