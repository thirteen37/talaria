import Testing
@testable import HermesKit

@Suite
struct HermesUpdatesTests {
    @Test
    func parsesCurrentLatestCommaForm() throws {
        let status = try #require(HermesUpdates.parse("current 1.2.3, latest 1.3.0"))
        #expect(status.current == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(status.latest == HermesVersion(major: 1, minor: 3, patch: 0))
        #expect(status.available)
    }

    @Test
    func parsesCurrentLatestColonForm() throws {
        let status = try #require(HermesUpdates.parse("current: 2.0.0\nlatest: 2.0.0"))
        #expect(status.current == HermesVersion(major: 2, minor: 0, patch: 0))
        #expect(status.latest == HermesVersion(major: 2, minor: 0, patch: 0))
        #expect(!status.available)
    }

    @Test
    func parsesUpToDateForm() throws {
        let status = try #require(HermesUpdates.parse("Up to date (1.4.2)"))
        #expect(status.current == HermesVersion(major: 1, minor: 4, patch: 2))
        #expect(!status.available)
    }

    @Test
    func parsesUpdateAvailableArrowForm() throws {
        let status = try #require(HermesUpdates.parse("Update available: 1.2.3 → 1.3.0"))
        #expect(status.current == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(status.latest == HermesVersion(major: 1, minor: 3, patch: 0))
        #expect(status.available)
    }

    @Test
    func parsesUpdateAvailableAsciiArrowForm() throws {
        let status = try #require(HermesUpdates.parse("Update available: 1.2.3 -> 1.3.0"))
        #expect(status.current == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(status.latest == HermesVersion(major: 1, minor: 3, patch: 0))
        #expect(status.available)
    }

    @Test
    func parsesCommitsBehindWithoutSemver() throws {
        // Source-install hermes: `update --check` returns a commit count
        // instead of a version delta. Before this fix the parser threw
        // parseError and the UI banner read "Update check is unavailable
        // in this Hermes version."
        let text = """
        → Fetching from upstream...
        → Fetching from origin...
        ⚕ Update available: 122 commits behind origin/main.
          Run 'hermes update' to install.
        """
        let status = try #require(HermesUpdates.parse(text))
        #expect(status.available)
        #expect(status.current == nil)
        #expect(status.latest == nil)
        #expect(status.detail == "Update available: 122 commits behind origin/main.")
    }

    @Test
    func parsesSourceInstallUpToDate() throws {
        // Detail must NOT just echo the headline ("Up to date"); it carries
        // the descriptor part so the banner's subtitle adds information.
        let status = try #require(HermesUpdates.parse("⚕ Up to date with origin/main."))
        #expect(!status.available)
        #expect(status.detail == "with origin/main")
    }

    @Test
    func upToDateWithNoQualifierLeavesDetailNil() throws {
        // No tail to peel off → detail nil so the banner only shows the
        // "Up to date" headline (UpdatesView's subtitle resolver returns
        // nil too in that case).
        let status = try #require(HermesUpdates.parse("Up to date."))
        #expect(!status.available)
        #expect(status.detail == nil)
    }

    @Test
    func checkSurfacesEnvBinaryNotFoundAsCommandFailed() async {
        // Regression: when `env hermes …` can't find the binary the bare
        // `"no such"` matcher mislabelled the failure as
        // "Update check is unavailable in this Hermes version."
        let runner = StubAdminRunner(result: HermesAdminResult(
            exitCode: 127,
            stdout: "",
            stderr: "env: hermes: No such file or directory\n"
        ))
        do {
            _ = try await HermesUpdates.check(runner: runner)
            #expect(Bool(false), "check should have thrown")
        } catch let error as HermesUpdatesError {
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
    func checkSurfacesUnknownSubcommandAsCommandUnavailable() async {
        let runner = StubAdminRunner(result: HermesAdminResult(
            exitCode: 2,
            stdout: "",
            stderr: "hermes: no such command 'update'\n"
        ))
        do {
            _ = try await HermesUpdates.check(runner: runner)
            #expect(Bool(false), "check should have thrown")
        } catch let error as HermesUpdatesError {
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

private struct StubAdminRunner: HermesAdminRunning {
    let result: HermesAdminResult

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        result
    }
}
