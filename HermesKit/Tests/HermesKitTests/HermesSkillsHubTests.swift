import Foundation
import Testing
@testable import HermesKit

/// Records every `HermesAdminCommand` (argv + env + stdin) and returns a canned
/// result, so command shape and the stdin-confirm seam can be asserted without
/// spawning a real hermes process.
private final class RecordingAdminRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [HermesAdminCommand] = []
    private let result: HermesAdminResult

    init(result: HermesAdminResult = HermesAdminResult(exitCode: 0, stdout: "", stderr: "")) {
        self.result = result
    }

    var commands: [HermesAdminCommand] { lock.withLock { _commands } }
    var lastCommand: HermesAdminCommand? { lock.withLock { _commands.last } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _commands.append(command) }
        return result
    }

    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        lock.withLock { _commands.append(command) }
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite
struct HermesSkillsHubTests {
    // MARK: - Command shape

    @Test
    func installSendsYesAndSeparatorBeforeIdentifier() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "Installed: official/foo\n", stderr: "")
        )
        let summary = try await HermesSkillsHub.install(runner: runner, identifier: "official/skills/foo")
        #expect(runner.lastCommand?.arguments == ["skills", "install", "--yes", "--", "official/skills/foo"])
        #expect(runner.lastCommand?.stdinInput == nil)
        #expect(summary == "Installed: official/foo")
    }

    @Test
    func uninstallFeedsYesOnStdin() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "Removed foo\n", stderr: "")
        )
        try await HermesSkillsHub.uninstall(runner: runner, name: "foo")
        #expect(runner.lastCommand?.arguments == ["skills", "uninstall", "--", "foo"])
        #expect(runner.lastCommand?.stdinInput == "y\n")
    }

    @Test
    func updateAllOmitsName() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.update(runner: runner)
        #expect(runner.lastCommand?.arguments == ["skills", "update"])
    }

    @Test
    func updateNamedAppendsSeparatorAndName() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.update(runner: runner, name: "foo")
        #expect(runner.lastCommand?.arguments == ["skills", "update", "--", "foo"])
    }

    @Test
    func listSetsWideColorFreeEnvironment() async throws {
        let runner = RecordingAdminRunner()
        _ = try await HermesSkillsHub.listInstalled(runner: runner)
        #expect(runner.lastCommand?.arguments == ["skills", "list"])
        #expect(runner.lastCommand?.environment["COLUMNS"] == "400")
        #expect(runner.lastCommand?.environment["NO_COLOR"] == "1")
    }

    @Test
    func checkSetsWideColorFreeEnvironment() async throws {
        let runner = RecordingAdminRunner()
        _ = try await HermesSkillsHub.checkUpdates(runner: runner)
        #expect(runner.lastCommand?.arguments == ["skills", "check"])
        #expect(runner.lastCommand?.environment["COLUMNS"] == "400")
        #expect(runner.lastCommand?.environment["NO_COLOR"] == "1")
    }

    // MARK: - Lifecycle command shape

    @Test
    func auditPassesNameAfterSeparatorAndReturnsReport() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "Audit OK: no issues\n", stderr: "")
        )
        let report = try await HermesSkillsHub.audit(runner: runner, name: "foo")
        #expect(runner.lastCommand?.arguments == ["skills", "audit", "--", "foo"])
        #expect(report == "Audit OK: no issues")
    }

    @Test
    func resetSendsSafeVariantWithName() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.reset(runner: runner, name: "pixel-art")
        // Safe default — no `--restore`, so no stdin prompt is needed.
        #expect(runner.lastCommand?.arguments == ["skills", "reset", "--", "pixel-art"])
        #expect(runner.lastCommand?.stdinInput == nil)
    }

    @Test
    func repairOfficialSendsSafeVariantWithName() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.repairOfficial(runner: runner, name: "dogfood")
        // Safe default — no `--restore`, so no stdin prompt is needed.
        #expect(runner.lastCommand?.arguments == ["skills", "repair-official", "--", "dogfood"])
        #expect(runner.lastCommand?.stdinInput == nil)
    }

    @Test
    func optOutSendsSafeVariant() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.optOut(runner: runner)
        // Safe default — writes the marker only, no `--remove`.
        #expect(runner.lastCommand?.arguments == ["skills", "opt-out"])
        #expect(runner.lastCommand?.stdinInput == nil)
    }

    @Test
    func optInWithoutSyncOmitsFlag() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.optIn(runner: runner)
        #expect(runner.lastCommand?.arguments == ["skills", "opt-in"])
    }

    @Test
    func optInWithSyncAppendsFlag() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.optIn(runner: runner, sync: true)
        #expect(runner.lastCommand?.arguments == ["skills", "opt-in", "--sync"])
    }

    @Test
    func publishToGithubPassesPathRegistryAndRepo() async throws {
        let runner = RecordingAdminRunner(
            result: HermesAdminResult(exitCode: 0, stdout: "Published to openai/skills\n", stderr: "")
        )
        let summary = try await HermesSkillsHub.publish(
            runner: runner,
            path: "/Users/me/.hermes/skills/tools/foo",
            registry: .github,
            repo: "openai/skills"
        )
        #expect(runner.lastCommand?.arguments == [
            "skills", "publish", "/Users/me/.hermes/skills/tools/foo",
            "--to", "github", "--repo", "openai/skills",
        ])
        #expect(summary == "Published to openai/skills")
    }

    @Test
    func publishToClawhubOmitsRepoWhenEmpty() async throws {
        let runner = RecordingAdminRunner()
        try await HermesSkillsHub.publish(
            runner: runner,
            path: "/Users/me/.hermes/skills/foo",
            registry: .clawhub,
            repo: nil
        )
        // clawhub doesn't require a repo — `--repo` is dropped when absent.
        #expect(runner.lastCommand?.arguments == [
            "skills", "publish", "/Users/me/.hermes/skills/foo", "--to", "clawhub",
        ])
    }

    @Test
    func lifecycleCommandsPropagateCommandUnavailable() async throws {
        // An older Hermes without the lifecycle subcommands surfaces argparse's
        // "no such command" as `.commandUnavailable`, not a generic failure.
        let runner = RecordingAdminRunner(result: HermesAdminResult(
            exitCode: 2, stdout: "", stderr: "hermes: no such command 'audit'\n"
        ))
        await #expect(throws: HermesSkillsHubError.self) {
            try await HermesSkillsHub.audit(runner: runner, name: "foo")
        }
        do {
            try await HermesSkillsHub.optOut(runner: runner)
            Issue.record("expected throw")
        } catch let error as HermesSkillsHubError {
            guard case .commandUnavailable = error else {
                Issue.record("expected commandUnavailable, got \(error)")
                return
            }
        } catch { Issue.record("unexpected \(error)") }
    }

    // MARK: - Skill-kind classification

    @Test
    func classifiesBuiltinAndOfficial() {
        let builtin = InstalledHubSkill(
            name: "dogfood", category: nil, source: "builtin", trust: "builtin", enabled: true
        )
        #expect(builtin.isBuiltin == true)
        #expect(builtin.isOfficial == false)

        let official = InstalledHubSkill(
            name: "writer", category: nil, source: "builtin", trust: "official", enabled: true
        )
        #expect(official.isBuiltin == true)
        #expect(official.isOfficial == true)

        let hub = InstalledHubSkill(
            name: "foo", category: nil, source: "skills-sh", trust: "community", enabled: true
        )
        #expect(hub.isBuiltin == false)
        #expect(hub.isOfficial == false)
    }

    // MARK: - Installed-table parsing

    @Test
    func parsesInstalledTableAndFlagsHubManaged() throws {
        // Real `hermes skills list` shape: builtin/local rows read "builtin"/
        // "local" in Source; a hub row reads its origin (here `skills-sh`) and a
        // non-builtin/local Trust. The long skills-sh name exercises a wide cell.
        let text = """
                                           Installed Skills
        ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━┓
        ┃ Name                      ┃ Category   ┃ Source  ┃ Trust     ┃ Status   ┃
        ┡━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━┩
        │ cmux                      │            │ local   │ local     │ enabled  │
        │ dogfood                   │            │ builtin │ builtin   │ enabled  │
        │ pixel-art                 │ creative   │ builtin │ builtin   │ disabled │
        │ skills-sh/github/foo-bar  │ tools      │ skills-sh │ community │ enabled  │
        └───────────────────────────┴────────────┴─────────┴───────────┴──────────┘
        """
        let rows = HermesSkillsHub.parseInstalledTable(text)
        #expect(rows.count == 4)

        let cmux = try #require(rows.first(where: { $0.name == "cmux" }))
        #expect(cmux.source == "local")
        #expect(cmux.category == nil)
        #expect(cmux.enabled == true)
        #expect(cmux.isHubManaged == false)

        let dogfood = try #require(rows.first(where: { $0.name == "dogfood" }))
        #expect(dogfood.isHubManaged == false)

        let pixel = try #require(rows.first(where: { $0.name == "pixel-art" }))
        #expect(pixel.category == "creative")
        #expect(pixel.enabled == false)
        #expect(pixel.isHubManaged == false)

        let hub = try #require(rows.first(where: { $0.name == "skills-sh/github/foo-bar" }))
        #expect(hub.source == "skills-sh")
        #expect(hub.trust == "community")
        #expect(hub.enabled == true)
        #expect(hub.isHubManaged == true)
    }

    @Test
    func classifiesOriginAsLocalBuiltinOrHub() throws {
        // The three origins must classify cleanly: local → isLocal only,
        // builtin → neither flag, hub → isHubManaged only.
        let text = """
                                           Installed Skills
        ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━┓
        ┃ Name                      ┃ Category   ┃ Source  ┃ Trust     ┃ Status   ┃
        ┡━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━┩
        │ cmux                      │            │ local   │ local     │ enabled  │
        │ dogfood                   │            │ builtin │ builtin   │ enabled  │
        │ pixel-art                 │ creative   │ builtin │ builtin   │ disabled │
        │ skills-sh/github/foo-bar  │ tools      │ skills-sh │ community │ enabled  │
        └───────────────────────────┴────────────┴─────────┴───────────┴──────────┘
        """
        let rows = HermesSkillsHub.parseInstalledTable(text)

        let cmux = try #require(rows.first(where: { $0.name == "cmux" }))
        #expect(cmux.isLocal == true)
        #expect(cmux.isHubManaged == false)

        let dogfood = try #require(rows.first(where: { $0.name == "dogfood" }))
        #expect(dogfood.isLocal == false)
        #expect(dogfood.isHubManaged == false)

        let pixel = try #require(rows.first(where: { $0.name == "pixel-art" }))
        #expect(pixel.isLocal == false)
        #expect(pixel.isHubManaged == false)

        let hub = try #require(rows.first(where: { $0.name == "skills-sh/github/foo-bar" }))
        #expect(hub.isLocal == false)
        #expect(hub.isHubManaged == true)
    }

    @Test
    func mergesWrappedContinuationRow() {
        // A continuation row (empty first cell) appends its non-empty cells to
        // the previous record — here a Category that wrapped onto a second line.
        let text = """
        │ alpha   │ very-long-cate │ skills-sh │ community │ enabled  │
        │         │ gory-name      │           │           │          │
        """
        let rows = HermesSkillsHub.parseInstalledTable(text)
        #expect(rows.count == 1)
        #expect(rows[0].name == "alpha")
        #expect(rows[0].category == "very-long-cate gory-name")
        #expect(rows[0].source == "skills-sh")
    }

    // MARK: - Check-table parsing

    @Test
    func parsesCheckTable() throws {
        let text = """
                       Skill Updates
        ┏━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━┓
        ┃ Name             ┃ Source    ┃ Status           ┃
        ┡━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━┩
        │ foo              │ official  │ update_available │
        │ bar              │ github    │ up_to_date       │
        └──────────────────┴───────────┴──────────────────┘
        """
        let rows = HermesSkillsHub.parseCheckTable(text)
        #expect(rows.count == 2)
        let foo = try #require(rows.first(where: { $0.name == "foo" }))
        #expect(foo.source == "official")
        #expect(foo.status == "update_available")
        #expect(foo.updateAvailable == true)
        let bar = try #require(rows.first(where: { $0.name == "bar" }))
        #expect(bar.updateAvailable == false)
    }

    @Test
    func checkSentinelYieldsNoRows() {
        let rows = HermesSkillsHub.parseCheckTable("No hub-installed skills to check.\n")
        #expect(rows.isEmpty)
    }

    // MARK: - Result classification

    @Test
    func ensureSuccessMapsUnknownCommandToUnavailable() {
        let result = HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: no such command 'skills'\n")
        #expect(throws: HermesSkillsHubError.self) {
            try HermesSkillsHub.ensureSuccess(result)
        }
        do {
            try HermesSkillsHub.ensureSuccess(result)
        } catch let error as HermesSkillsHubError {
            guard case .commandUnavailable = error else {
                Issue.record("expected commandUnavailable, got \(error)")
                return
            }
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        let result = HermesAdminResult(exitCode: 127, stdout: "", stderr: "env: hermes: No such file or directory\n")
        do {
            try HermesSkillsHub.ensureSuccess(result)
            Issue.record("expected throw")
        } catch let error as HermesSkillsHubError {
            guard case .commandFailed = error else {
                Issue.record("expected commandFailed, got \(error)")
                return
            }
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test
    func installRejectsBlockedScanDespiteZeroExit() async throws {
        // `skills install` prints a block reason and exits 0 — must surface as a
        // thrown rejection, not a silent success.
        let runner = RecordingAdminRunner(result: HermesAdminResult(
            exitCode: 0,
            stdout: "Running security scan...\nInstallation blocked: dangerous verdict\n",
            stderr: ""
        ))
        await #expect(throws: HermesSkillsHubError.self) {
            try await HermesSkillsHub.install(runner: runner, identifier: "sketchy/skill")
        }
    }

    @Test
    func uninstallRejectsCancelledOutput() async throws {
        // If the confirm somehow didn't take (e.g. a runner that drops stdin),
        // "Cancelled." in stdout must surface rather than read as removed.
        let runner = RecordingAdminRunner(result: HermesAdminResult(
            exitCode: 0, stdout: "Uninstall 'foo'?\nCancelled.\n", stderr: ""
        ))
        await #expect(throws: HermesSkillsHubError.self) {
            try await HermesSkillsHub.uninstall(runner: runner, name: "foo")
        }
    }
}
