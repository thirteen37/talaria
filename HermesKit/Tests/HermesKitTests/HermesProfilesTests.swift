import Foundation
import Testing
@testable import HermesKit

/// Records every command's argv so `HermesProfiles` write builders can be
/// verified without spawning a real hermes process. Returns a canned result
/// (success by default, or a configured failure).
private final class RecordingAdminRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [[String]] = []
    private let result: HermesAdminResult

    init(result: HermesAdminResult = HermesAdminResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    var arguments: [[String]] { lock.withLock { _arguments } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _arguments.append(command.arguments) }
        return result
    }

    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        lock.withLock { _arguments.append(command.arguments) }
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite
struct HermesProfilesTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Write builders

    @Test
    func createBuildsCloneArgv() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.create(runner: runner, name: "work", cloneFrom: "default")
        #expect(runner.arguments == [["profile", "create", "work", "--clone", "--clone-from", "default"]])
    }

    @Test
    func createClonesFromArbitrarySource() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.create(runner: runner, name: "office", cloneFrom: "work")
        #expect(runner.arguments == [["profile", "create", "office", "--clone", "--clone-from", "work"]])
    }

    @Test
    func renameBuildsRenameArgv() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.rename(runner: runner, from: "work", to: "office")
        #expect(runner.arguments == [["profile", "rename", "work", "office"]])
    }

    @Test
    func deleteBuildsDeleteArgvWithYes() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.delete(runner: runner, name: "work")
        #expect(runner.arguments == [["profile", "delete", "work", "-y"]])
    }

    @Test
    func writeMapsUnknownCommandToCommandUnavailable() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: no such command 'profile'\n")
        )
        await #expect(throws: HermesProfilesError.self) {
            try await HermesProfiles.create(runner: runner, name: "work", cloneFrom: "default")
        }
        do {
            try await HermesProfiles.create(runner: runner, name: "work", cloneFrom: "default")
        } catch let error as HermesProfilesError {
            guard case .commandUnavailable = error else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
                return
            }
        }
    }

    @Test
    func parsesRichTable() throws {
        let profiles = HermesProfiles.parse(try fixture("profiles-rich"))
        #expect(profiles.map(\.name) == ["default", "work", "staging"])
        let def = try #require(profiles.first(where: { $0.name == "default" }))
        #expect(def.isDefault == true)
        #expect(def.status == "running")
        let work = try #require(profiles.first(where: { $0.name == "work" }))
        #expect(work.isDefault == false)
        #expect(work.status == "stopped")
        let staging = try #require(profiles.first(where: { $0.name == "staging" }))
        #expect(staging.isDefault == false)
        #expect(staging.status == nil)
    }

    @Test
    func parsesPlainTable() throws {
        let profiles = HermesProfiles.parse(try fixture("profiles-plain"))
        #expect(profiles.map(\.name) == ["default", "work", "staging"])
        #expect(profiles.first(where: { $0.name == "default" })?.isDefault == true)
        #expect(profiles.first(where: { $0.name == "work" })?.status == "stopped")
        #expect(profiles.first(where: { $0.name == "staging" })?.status == nil)
    }

    @Test
    func plainParseKeepsProfilesWhoseNameStartsWithName() {
        // Regression: a bare `hasPrefix("name")` header heuristic silently
        // dropped profiles like "namespace" / "name-test" from the plain path.
        let profiles = HermesProfiles.parse("namespace\nname-test\nwork")
        #expect(profiles.map(\.name) == ["namespace", "name-test", "work"])
    }

    @Test
    func plainParseStillSkipsRealHeaderRow() {
        let profiles = HermesProfiles.parse("Name       Default  Status\nwork       no       running")
        #expect(profiles.map(\.name) == ["work"])
    }

    @Test
    func ensureDefaultInjectsMissingDefaultRow() {
        let parsed = HermesProfiles.parse("work\nstaging")
        #expect(!parsed.contains(where: { $0.name == "default" }))
        let ensured = HermesProfiles.ensureDefault(parsed)
        #expect(ensured.map(\.name) == ["default", "work", "staging"])
        #expect(ensured.first?.isDefault == true)
    }

    @Test
    func ensureDefaultLeavesExistingDefaultUntouched() {
        let parsed = HermesProfiles.parse("default running\nwork")
        let ensured = HermesProfiles.ensureDefault(parsed)
        #expect(ensured.filter { $0.name == "default" }.count == 1)
        #expect(ensured.count == 2)
    }

    @Test
    func ensureSuccessThrowsCommandUnavailableForUnknownCommand() {
        let result = HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: no such command 'profile'\n")
        do {
            try HermesProfiles.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesProfilesError {
            if case .commandUnavailable = error {} else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        let result = HermesAdminResult(exitCode: 127, stdout: "", stderr: "env: hermes: No such file or directory\n")
        do {
            try HermesProfiles.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesProfilesError {
            if case .commandFailed = error {} else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}
