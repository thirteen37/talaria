import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesCronTests {
    @Test
    func parsesIndentedBlockFormat() throws {
        // Regression: real hermes emits a banner followed by indented
        // `<id> [active|paused]` / `    Key: value` blocks. The old
        // per-line parser tried to match `id  schedule  command  enabled`
        // and grabbed key-value lines like `    Last run: 2026-…  ok` as
        // bogus rows.
        let url = try #require(Bundle.module.url(forResource: "Fixtures/cron-rich", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let jobs = HermesCron.parse(text)
        #expect(jobs.count == 2)
        let first = try #require(jobs.first)
        #expect(first.id == "c164af3d9600")
        #expect(first.schedule == "0 9 * * *")
        #expect(first.command == "talaria-fixture")
        #expect(first.enabled == true)
        let second = jobs[1]
        #expect(second.id == "f19e42b678fe")
        #expect(second.schedule == "*/15 * * * *")
        #expect(second.command == "another")
        #expect(second.enabled == true)
    }

    @Test
    func recognizesPausedStatus() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/cron-rich-paused", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let jobs = HermesCron.parse(text)
        #expect(jobs.count == 2)
        let paused = try #require(jobs.first(where: { $0.id == "c164af3d9600" }))
        #expect(paused.enabled == false, "[paused] status must not register as enabled")
        let active = try #require(jobs.first(where: { $0.id == "f19e42b678fe" }))
        #expect(active.enabled == true)
    }

    @Test
    func parsesTabSeparatedRows() {
        let text = "job1\t0 9 * * 1-5\thermes update\tyes\t2026-05-23T08:00:00Z\n"
                 + "job2\t*/15 * * * *\thermes doctor\tno\t-\n"
        let jobs = HermesCron.parse(text)
        #expect(jobs.count == 2)
        #expect(jobs[0].id == "job1")
        #expect(jobs[0].schedule == "0 9 * * 1-5")
        #expect(jobs[0].command == "hermes update")
        #expect(jobs[0].enabled == true)
        #expect(jobs[0].lastRun != nil)
        #expect(jobs[1].id == "job2")
        #expect(jobs[1].enabled == false)
        #expect(jobs[1].lastRun == nil)
    }

    @Test
    func parsesSpaceAlignedRows() {
        let text = """
        id      schedule         command         enabled  last_run
        ------  ---------------  --------------  -------  -------------------
        job1    0 9 * * 1-5      hermes update   yes      2026-05-23 08:00:00
        job2    */15 * * * *     hermes doctor   no       -
        """
        let jobs = HermesCron.parse(text)
        #expect(jobs.count == 2)
        #expect(jobs[0].id == "job1")
        #expect(jobs[0].schedule == "0 9 * * 1-5")
        #expect(jobs[0].command == "hermes update")
        #expect(jobs[0].enabled == true)
        #expect(jobs[0].lastRun != nil)
        #expect(jobs[1].enabled == false)
    }

    @Test
    func ensureSuccessThrowsCommandUnavailableForUnknownCommand() {
        let result = HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: unknown command 'cron add'\n")
        #expect(throws: HermesCronError.self) {
            try HermesCron.ensureSuccess(result)
        }
        do {
            try HermesCron.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesCronError {
            if case .commandUnavailable = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }

    @Test
    func ensureSuccessThrowsCommandFailedForOtherErrors() {
        let result = HermesAdminResult(exitCode: 1, stdout: "", stderr: "invalid schedule\n")
        do {
            try HermesCron.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesCronError {
            if case .commandFailed = error {
                // ok
            } else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}
