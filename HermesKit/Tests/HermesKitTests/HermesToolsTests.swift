import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesToolsTests {
    @Test
    func buildsPlatformScopedCommands() async throws {
        let runner = RecordingToolsRunner()

        _ = try await HermesTools.list(runner: runner, platform: "slack")
        try await HermesTools.enable(runner: runner, name: "web", platform: "cli")
        try await HermesTools.disable(runner: runner, name: "shell", platform: "telegram")
        _ = try await HermesTools.list(runner: runner)
        try await HermesTools.enable(runner: runner, name: "web")
        try await HermesTools.disable(runner: runner, name: "shell")

        #expect(runner.runArguments == [
            ["tools", "list", "--platform", "slack"],
            ["tools", "enable", "--platform", "cli", "--", "web"],
            ["tools", "disable", "--platform", "telegram", "--", "shell"],
            ["tools", "list"],
            ["tools", "enable", "--", "web"],
            ["tools", "disable", "--", "shell"],
        ])
    }

    @Test
    func makeMatrixUnionsRowsByPlatformOrder() throws {
        let matrix = HermesTools.makeMatrix(
            platforms: ["cli", "slack", "telegram"],
            byPlatform: [
                "cli": [
                    ToolRow(name: "web", platform: "🔍 Web Search & Scraping", enabled: true),
                    ToolRow(name: "shell", platform: "🐚 Shell Commands", enabled: false),
                ],
                "slack": [
                    ToolRow(name: "web", platform: "ignored later label", enabled: false),
                    ToolRow(name: "video", platform: "🎬 Video Analysis", enabled: true),
                ],
            ]
        )

        #expect(matrix.platforms == ["cli", "slack", "telegram"])
        #expect(matrix.rows.map(\.name) == ["web", "shell", "video"])

        let web = try #require(matrix.rows.first { $0.name == "web" })
        #expect(web.label == "🔍 Web Search & Scraping")
        #expect(web.enabledByPlatform["cli"] == true)
        #expect(web.enabledByPlatform["slack"] == false)
        #expect(web.enabledByPlatform["telegram"] == nil)

        let shell = try #require(matrix.rows.first { $0.name == "shell" })
        #expect(shell.enabledByPlatform == ["cli": false])

        let video = try #require(matrix.rows.first { $0.name == "video" })
        #expect(video.label == "🎬 Video Analysis")
        #expect(video.enabledByPlatform == ["slack": true])
    }

    @Test
    func loadMatrixToleratesOnePlatformFailure() async throws {
        let runner = RecordingToolsRunner(
            stdoutByPlatform: [
                "cli": """
                Built-in toolsets (cli):
                  ✓ enabled   web     🔍 Web Search & Scraping
                """,
                "telegram": """
                Built-in toolsets (telegram):
                  ✗ disabled  web     🔍 Web Search & Scraping
                  ✓ enabled   shell   🐚 Shell Commands
                """,
            ],
            failingPlatforms: ["slack"]
        )

        let matrix = try await HermesTools.loadMatrix(
            runner: runner,
            platforms: ["cli", "slack", "telegram"]
        )

        #expect(matrix.platforms == ["cli", "slack", "telegram"])
        let web = try #require(matrix.rows.first { $0.name == "web" })
        #expect(web.enabledByPlatform["cli"] == true)
        #expect(web.enabledByPlatform["slack"] == nil)
        #expect(web.enabledByPlatform["telegram"] == false)
        let shell = try #require(matrix.rows.first { $0.name == "shell" })
        #expect(shell.enabledByPlatform["telegram"] == true)
        #expect(shell.enabledByPlatform["slack"] == nil)
    }

    @Test
    func replacingColumnUpdatesOnlyTheNamedPlatform() throws {
        let matrix = HermesTools.makeMatrix(
            platforms: ["cli", "slack"],
            byPlatform: [
                "cli": [
                    ToolRow(name: "web", platform: "🔍 Web Search & Scraping", enabled: true),
                    ToolRow(name: "shell", platform: "🐚 Shell Commands", enabled: true),
                ],
                "slack": [
                    ToolRow(name: "web", platform: nil, enabled: true),
                    ToolRow(name: "shell", platform: nil, enabled: false),
                ],
            ]
        )

        // Re-list slack with `web` now disabled; cli must be untouched.
        let updated = matrix.replacingColumn("slack", with: [
            ToolRow(name: "web", platform: nil, enabled: false),
            ToolRow(name: "shell", platform: nil, enabled: false),
        ])

        #expect(updated.platforms == ["cli", "slack"])
        #expect(updated.rows.map(\.name) == ["web", "shell"])   // order preserved
        let web = try #require(updated.rows.first { $0.name == "web" })
        #expect(web.enabledByPlatform["slack"] == false)         // toggled column updated
        #expect(web.enabledByPlatform["cli"] == true)            // other column untouched
        #expect(web.label == "🔍 Web Search & Scraping")         // existing label kept
    }

    @Test
    func replacingColumnClearsToolsNoLongerReportedForThatPlatform() throws {
        let matrix = HermesTools.makeMatrix(
            platforms: ["cli", "slack"],
            byPlatform: [
                "cli": [ToolRow(name: "web", platform: nil, enabled: true)],
                "slack": [ToolRow(name: "web", platform: nil, enabled: true)],
            ]
        )

        // slack no longer reports `web` → its slack cell becomes unknown (absent),
        // while cli stays known.
        let updated = matrix.replacingColumn("slack", with: [])
        let web = try #require(updated.rows.first { $0.name == "web" })
        #expect(web.enabledByPlatform["slack"] == nil)
        #expect(web.enabledByPlatform["cli"] == true)
    }

    @Test
    func replacingColumnAppendsToolsNewToThatPlatform() throws {
        let matrix = HermesTools.makeMatrix(
            platforms: ["cli", "slack"],
            byPlatform: ["cli": [ToolRow(name: "web", platform: nil, enabled: true)]]
        )

        let updated = matrix.replacingColumn("slack", with: [
            ToolRow(name: "video", platform: "🎬 Video Analysis", enabled: true),
        ])
        #expect(updated.rows.map(\.name) == ["web", "video"])
        let video = try #require(updated.rows.first { $0.name == "video" })
        #expect(video.enabledByPlatform == ["slack": true])
        #expect(video.label == "🎬 Video Analysis")
    }

    @Test
    func loadMatrixThrowsWhenEveryPlatformFails() async throws {
        let runner = RecordingToolsRunner(failingPlatforms: ["cli", "slack"])

        do {
            _ = try await HermesTools.loadMatrix(runner: runner, platforms: ["cli", "slack"])
            Issue.record("Expected loadMatrix to throw when every platform fails")
        } catch {
            #expect(error.localizedDescription.contains("failed"))
        }
    }

    @Test
    func parsesBulletFormatFromRealHermes() throws {
        // Regression: real `hermes tools list` emits lines like
        //   `  ✓ enabled  web  🔍 Web Search & Scraping`
        // The previous parser fell through to the bare "name only" arm
        // because nothing matched `[x]` brackets, leaving `name = "✓"` for
        // every row and rolling the rest into the platform column.
        let text = """
        Built-in toolsets (cli):
          ✓ enabled   web     🔍 Web Search & Scraping
          ✗ disabled  video   🎬 Video Analysis
          ✓ enabled   shell   🐚 Shell Commands
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        let web = try #require(rows.first(where: { $0.name == "web" }))
        #expect(web.enabled == true)
        #expect(web.platform == "🔍 Web Search & Scraping")
        let video = try #require(rows.first(where: { $0.name == "video" }))
        #expect(video.enabled == false)
        #expect(video.platform == "🎬 Video Analysis")
        // No row should be named with the literal bullet glyph or status word.
        for row in rows {
            #expect(row.name != "✓")
            #expect(row.name != "✗")
            #expect(row.name != "enabled")
            #expect(row.name != "disabled")
        }
    }

    @Test
    func parsesCheckboxStyle() {
        let text = """
        [x] Bash    posix
        [x] Read    universal
        [ ] Edit    universal
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ToolRow(name: "Bash", platform: "posix", enabled: true))
        #expect(rows[1] == ToolRow(name: "Read", platform: "universal", enabled: true))
        #expect(rows[2] == ToolRow(name: "Edit", platform: "universal", enabled: false))
    }

    @Test
    func parsesTableStyle() {
        let text = """
        name    platform   enabled
        ------  ---------  -------
        Bash    posix      yes
        Read    universal  yes
        Edit    universal  no
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ToolRow(name: "Bash", platform: "posix", enabled: true))
        #expect(rows[2] == ToolRow(name: "Edit", platform: "universal", enabled: false))
    }

    @Test
    func parsesBareNames() {
        let text = """
        alpha
        beta
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.enabled })
        #expect(rows.allSatisfy { $0.platform == nil })
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        // Regression: `env: hermes: No such file or directory` (PATH miss)
        // used to be mistaken for "tools subcommand missing in this hermes".
        let result = HermesAdminResult(
            exitCode: 127,
            stdout: "",
            stderr: "env: hermes: No such file or directory\n"
        )
        do {
            try HermesTools.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesToolsError {
            if case .commandFailed = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }

    @Test
    func ensureSuccessThrowsCommandUnavailableForUnknownCommand() {
        let result = HermesAdminResult(
            exitCode: 2,
            stdout: "",
            stderr: "hermes: no such command 'tools'\n"
        )
        do {
            try HermesTools.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesToolsError {
            if case .commandUnavailable = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}

private final class RecordingToolsRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _runArguments: [[String]] = []
    private let stdoutByPlatform: [String: String]
    private let failingPlatforms: Set<String>

    init(stdoutByPlatform: [String: String] = [:], failingPlatforms: Set<String> = []) {
        self.stdoutByPlatform = stdoutByPlatform
        self.failingPlatforms = failingPlatforms
    }

    var runArguments: [[String]] { lock.withLock { _runArguments } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        lock.withLock { _runArguments.append(command.arguments) }
        let platform = Self.platform(in: command.arguments)
        if failingPlatforms.contains(platform) {
            return HermesAdminResult(exitCode: 2, stdout: "", stderr: "tools list failed for \(platform)")
        }
        return HermesAdminResult(
            exitCode: 0,
            stdout: stdoutByPlatform[platform] ?? "",
            stderr: ""
        )
    }

    private static func platform(in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--platform"),
              arguments.indices.contains(index + 1) else {
            return "unscoped"
        }
        return arguments[index + 1]
    }
}
