import Foundation
import Testing
@testable import HermesKit

/// Records each command's argv and returns a canned result, so the
/// distribution write/read builders can be verified without spawning hermes.
private final class RecordingAdminRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _arguments: [[String]] = []
    private let result: HermesAdminResult

    init(result: HermesAdminResult = HermesAdminResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    var arguments: [[String]] { lock.withLock { _arguments } }
    var lastArguments: [String]? { lock.withLock { _arguments.last } }

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
struct HermesProfilesDistributionTests {
    // MARK: - install

    @Test
    func installBuildsMinimalArgvWithYes() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "Installed profile 'foo'\n", stderr: "")
        )
        let summary = try await HermesProfiles.install(runner: runner, source: "https://example.com/foo.git")
        #expect(runner.lastArguments == ["profile", "install", "https://example.com/foo.git", "-y"])
        #expect(summary == "Installed profile 'foo'")
    }

    @Test
    func installThreadsNameAliasForceBeforeYes() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.install(
            runner: runner,
            source: "/local/dir",
            name: "work",
            alias: true,
            force: true
        )
        #expect(runner.lastArguments == [
            "profile", "install", "/local/dir", "--name", "work", "--alias", "--force", "-y",
        ])
    }

    @Test
    func installOmitsEmptyName() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.install(runner: runner, source: "src", name: "")
        #expect(runner.lastArguments == ["profile", "install", "src", "-y"])
    }

    // MARK: - update

    @Test
    func updateBuildsArgvWithYes() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.update(runner: runner, name: "work")
        #expect(runner.lastArguments == ["profile", "update", "work", "-y"])
    }

    @Test
    func updateThreadsForceConfigBeforeYes() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.update(runner: runner, name: "work", forceConfig: true)
        #expect(runner.lastArguments == ["profile", "update", "work", "--force-config", "-y"])
    }

    // MARK: - export / import

    @Test
    func exportBuildsArgvWithOutputFlag() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.export(runner: runner, name: "work", outputPath: "/tmp/work.tar.gz")
        #expect(runner.lastArguments == ["profile", "export", "work", "-o", "/tmp/work.tar.gz"])
    }

    @Test
    func importBuildsArgvWithoutName() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "Imported 'work'\n", stderr: "")
        )
        let summary = try await HermesProfiles.importArchive(runner: runner, archivePath: "/tmp/work.tar.gz")
        #expect(runner.lastArguments == ["profile", "import", "/tmp/work.tar.gz"])
        #expect(summary == "Imported 'work'")
    }

    @Test
    func importThreadsNameFlag() async throws {
        let runner = RecordingAdminRunner()
        try await HermesProfiles.importArchive(runner: runner, archivePath: "/tmp/a.tar.gz", name: "copy")
        #expect(runner.lastArguments == ["profile", "import", "/tmp/a.tar.gz", "--name", "copy"])
    }

    // MARK: - profileDirectory

    @Test
    func profileDirectoryScopesNamedProfileAndReturnsParent() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "/home/u/.hermes/profiles/work/config.yaml\n", stderr: "")
        )
        let dir = try await HermesProfiles.profileDirectory(runner: runner, name: "work")
        #expect(runner.lastArguments == ["-p", "work", "config", "path"])
        #expect(dir == "/home/u/.hermes/profiles/work")
    }

    @Test
    func profileDirectoryLeavesDefaultUnscoped() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "/home/u/.hermes/config.yaml\n", stderr: "")
        )
        let dir = try await HermesProfiles.profileDirectory(runner: runner, name: "default")
        #expect(runner.lastArguments == ["config", "path"])
        #expect(dir == "/home/u/.hermes")
    }

    // MARK: - info / parseInfo

    @Test
    func infoBuildsArgv() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "name: work\nversion: 1.2.0\n", stderr: "")
        )
        let info = try await HermesProfiles.info(runner: runner, name: "work")
        #expect(runner.lastArguments == ["profile", "info", "work"])
        #expect(info.isDistribution)
        #expect(info.name == "work")
        #expect(info.version == "1.2.0")
    }

    @Test
    func infoDetectsNotADistributionSentinel() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(
                exitCode: 1,
                stdout: "Profile 'plain' is not a distribution (no distribution.yaml).\n",
                stderr: ""
            )
        )
        let info = try await HermesProfiles.info(runner: runner, name: "plain")
        #expect(info.isDistribution == false)
        #expect(info.rawText.contains("not a distribution"))
    }

    @Test
    func infoDetectsSentinelOnStderr() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(
                exitCode: 2,
                stdout: "",
                stderr: "Profile 'plain' is not a distribution (no distribution.yaml).\n"
            )
        )
        let info = try await HermesProfiles.info(runner: runner, name: "plain")
        #expect(info.isDistribution == false)
    }

    @Test
    func infoMapsUnknownCommandToCommandUnavailable() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: no such command 'profile'\n")
        )
        await #expect(throws: HermesProfilesError.self) {
            _ = try await HermesProfiles.info(runner: runner, name: "work")
        }
    }

    @Test
    func parseInfoExtractsHeadlineFieldsAndKeepsRawText() {
        let text = """
        name: cool-dist
        version: 2.0.1
        description: A cool distribution
        author: Jane Doe
        license: MIT
        source: https://github.com/jane/cool-dist.git
        hermes_requires: ">=0.15.0"
        """
        let info = HermesProfiles.parseInfo(text, profile: "cool")
        #expect(info.isDistribution)
        #expect(info.name == "cool-dist")
        #expect(info.version == "2.0.1")
        #expect(info.description == "A cool distribution")
        #expect(info.author == "Jane Doe")
        #expect(info.license == "MIT")
        #expect(info.source == "https://github.com/jane/cool-dist.git")
        #expect(info.hermesRequires == ">=0.15.0")
        #expect(info.rawText == text)
    }

    @Test
    func parseInfoParsesEnvRequiresBlock() {
        let text = """
        name: cool-dist
        env_requires:
          - name: OPENAI_API_KEY
            description: Your OpenAI key
            required: true
          - name: OPTIONAL_VAR
            required: false
            default: fallback
        license: MIT
        """
        let info = HermesProfiles.parseInfo(text, profile: "cool")
        #expect(info.envRequires.count == 2)
        let first = info.envRequires.first
        #expect(first?.name == "OPENAI_API_KEY")
        #expect(first?.description == "Your OpenAI key")
        #expect(first?.required == true)
        #expect(first?.defaultValue == nil)
        let second = info.envRequires.last
        #expect(second?.name == "OPTIONAL_VAR")
        #expect(second?.required == false)
        #expect(second?.defaultValue == "fallback")
        // A non-indented line after the block resumes headline parsing.
        #expect(info.license == "MIT")
    }

    @Test
    func parseInfoIsTolerantOfUnknownLines() {
        let info = HermesProfiles.parseInfo("garbage line without colon\nname: x", profile: "x")
        #expect(info.name == "x")
        #expect(info.isDistribution)
    }
}
