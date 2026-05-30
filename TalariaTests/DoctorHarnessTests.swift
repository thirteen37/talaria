import HermesKit
import Testing
@testable import Talaria

/// Stub admin runner that records the commands it receives and returns a canned
/// result. `HermesDoctorTests`' own `RecordingAdminRunner` is file-private to
/// HermesKitTests, so we re-declare a small one here.
private final class StubAdminRunner: HermesAdminRunning, @unchecked Sendable {
    let result: Result<HermesAdminResult, Error>
    private(set) var received: [[String]] = []

    init(_ result: Result<HermesAdminResult, Error>) { self.result = result }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        received.append(command.arguments)
        return try result.get()
    }
}

private struct StubError: Error {}

@MainActor
@Suite
struct DoctorHarnessTests {
    private func multiSectionResult() -> HermesAdminResult {
        HermesAdminResult(
            exitCode: 0,
            stdout: """
            ◆ Security Advisories
              No known advisories.

            ◆ Python Environment
              Python 3.11.15
            """,
            stderr: ""
        )
    }

    @Test
    func runDoctorPopulatesReportAndExpandsSections() async {
        let runner = StubAdminRunner(.success(multiSectionResult()))
        let harness = DoctorHarness(runner: runner)
        harness.runDoctor()
        await harness.waitForCompletion()

        let report = harness.report
        #expect(report != nil)
        let titles = report?.sections.map(\.title) ?? []
        #expect(titles.contains("Security Advisories"))
        #expect(titles.contains("Python Environment"))
        #expect(harness.expanded == Set(report?.sections.map(\.id) ?? []))
        #expect(harness.isRunning == false)
        #expect(harness.lastError == nil)
    }

    @Test
    func reportSurvivesIndependentOfAnyView() async {
        // The regression intent: the harness — not a view — owns the result, so
        // it remains readable after the run completes even though no view holds it.
        let runner = StubAdminRunner(.success(multiSectionResult()))
        let harness = DoctorHarness(runner: runner)
        harness.runDoctor()
        await harness.waitForCompletion()
        #expect(harness.report != nil)
    }

    @Test
    func runFixIssuesFixSubcommand() async {
        let runner = StubAdminRunner(.success(multiSectionResult()))
        let harness = DoctorHarness(runner: runner)
        harness.runFix()
        await harness.waitForCompletion()
        #expect(runner.received == [["doctor", "--fix"]])
    }

    @Test
    func runSurfacesErrorInLastError() async {
        let runner = StubAdminRunner(.failure(StubError()))
        let harness = DoctorHarness(runner: runner)
        harness.runDoctor()
        await harness.waitForCompletion()
        #expect(harness.lastError != nil)
        #expect(harness.report == nil)
        #expect(harness.isRunning == false)
    }

    @Test
    func runWithNilRunnerIsNoOp() async {
        let harness = DoctorHarness(runner: nil)
        harness.runDoctor()
        await harness.waitForCompletion()
        #expect(harness.report == nil)
        #expect(harness.isRunning == false)
        #expect(harness.lastError == nil)
    }
}
