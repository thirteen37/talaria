import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Stub admin runner returning canned `hermes update --check` output. A single
/// result is repeated for every call; a list is consumed one-per-call and the
/// last entry repeats once exhausted (so a test can change the reported version
/// between checks). Mirrors `DoctorHarnessTests`' file-private stub.
private final class StubAdminRunner: HermesAdminRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<HermesAdminResult, Error>]
    private(set) var received: [[String]] = []

    init(_ results: [Result<HermesAdminResult, Error>]) { self.results = results }
    convenience init(_ result: Result<HermesAdminResult, Error>) { self.init([result]) }

    var callCount: Int { lock.withLock { received.count } }

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        let result: Result<HermesAdminResult, Error> = lock.withLock {
            received.append(command.arguments)
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        return try result.get()
    }
}

private struct StubError: Error {}

private func checkResult(_ stdout: String) -> Result<HermesAdminResult, Error> {
    .success(HermesAdminResult(exitCode: 0, stdout: stdout, stderr: ""))
}

/// Returns canned commits and records how many times it was asked. Thread-safe
/// because the harness calls it from a detached (off-MainActor) changelog task.
private final class StubCommitFetcher: PendingCommitFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let commits: [PendingCommit]
    private var _callCount = 0

    init(_ commits: [PendingCommit]) { self.commits = commits }

    var callCount: Int { lock.withLock { _callCount } }

    func pendingCommits(limit: Int) async -> [PendingCommit] {
        lock.withLock { _callCount += 1 }
        return commits
    }
}

/// Returns a canned summary and records how many times it was asked.
private final class StubSummarizer: ChangelogSummarizing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: ChangelogSummary
    private var _callCount = 0

    init(_ result: ChangelogSummary) { self.result = result }

    var callCount: Int { lock.withLock { _callCount } }

    func summarize(commits: [PendingCommit]) async -> ChangelogSummary {
        lock.withLock { _callCount += 1 }
        return result
    }
}

/// Records `onUpdateAvailable` / `onUpdateCleared` invocations from the
/// `@MainActor` harness.
@MainActor
private final class NotifyRecorder {
    private(set) var count = 0
    private(set) var last: UpdateStatus?
    private(set) var clearedCount = 0
    func record(_ status: UpdateStatus) {
        count += 1
        last = status
    }
    func recordCleared() {
        clearedCount += 1
    }
}

@MainActor
@Suite
struct UpdatesHarnessTests {
    private func makeHarness(
        _ runner: HermesAdminRunning?,
        recorder: NotifyRecorder,
        fetcher: PendingCommitFetching? = nil,
        summarizer: ChangelogSummarizing? = nil
    ) -> UpdatesHarness {
        let harness = UpdatesHarness(runner: runner, commitFetcher: fetcher, summarizer: summarizer)
        harness.onUpdateAvailable = { status in recorder.record(status) }
        harness.onUpdateCleared = { recorder.recordCleared() }
        return harness
    }

    @Test
    func sourceInstallForegroundCheckSummarizesCommits() async {
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "Add gateway chat")])
        let summarizer = StubSummarizer(.summary(headline: "Faster chat", highlights: ["New gateway"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        // The model runs off-actor; the foreground check leaves it loading.
        #expect(harness.changelog == .loading)
        await harness.changelogTask?.value
        #expect(harness.changelog == .ready(.summary(headline: "Faster chat", highlights: ["New gateway"])))
        #expect(fetcher.callCount == 1)
        #expect(summarizer.callCount == 1)
    }

    @Test
    func semverForegroundCheckDoesNotSummarize() async {
        let runner = StubAdminRunner(checkResult("Update available: 1.2.3 → 1.3.0"))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        await harness.changelogTask?.value
        #expect(harness.changelog == .idle)
        #expect(fetcher.callCount == 0)
        #expect(summarizer.callCount == 0)
    }

    @Test
    func emptyCommitsLeavesChangelogUnavailable() async {
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        await harness.changelogTask?.value
        #expect(harness.changelog == .unavailable)
        // No commits → don't bother the model.
        #expect(summarizer.callCount == 0)
    }

    @Test
    func backgroundCheckNeverSummarizes() async {
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.backgroundCheck()
        await harness.changelogTask?.value
        #expect(harness.changelog == .idle)
        #expect(fetcher.callCount == 0)
        #expect(summarizer.callCount == 0)
    }

    @Test
    func reCheckCancelsPriorChangelogTask() async {
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        let firstTask = harness.changelogTask
        await harness.check()
        #expect(firstTask?.isCancelled == true)
        await harness.changelogTask?.value
        #expect(harness.changelog == .ready(.summary(headline: "H", highlights: ["a"])))
    }

    @Test
    func nilDepsLeaveChangelogIdle() async {
        // The default (production-untouched) wiring: no fetcher/summarizer means
        // the changelog stays idle and the existing subtitle path is used.
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.check()
        await harness.changelogTask?.value
        #expect(harness.changelog == .idle)
    }

    @Test
    func identicalCommitSetReusesCachedSummary() async {
        // Re-checking an unchanged update must not re-run the model — reuse the
        // cached summary keyed on the exact commit set.
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        await harness.changelogTask?.value
        #expect(summarizer.callCount == 1)

        await harness.check()
        await harness.changelogTask?.value
        // Fetched again to learn the current range, but the model wasn't re-run.
        #expect(fetcher.callCount == 2)
        #expect(summarizer.callCount == 1)
        #expect(harness.changelog == .ready(.summary(headline: "H", highlights: ["a"])))
    }

    @Test
    func changelogDoesNotFetchWhileProfileApplying() async {
        // Cross-window interlock: if another window on this profile is mid-apply
        // (a git pull on the shared repo), opening the Updates screen must not run
        // our git fetch and race the pull's ref update.
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)
        harness.isProfileApplying = { true }

        await harness.check()
        await harness.changelogTask?.value
        #expect(fetcher.callCount == 0)
        #expect(summarizer.callCount == 0)
    }

    @Test
    func ensureChangelogSummaryGeneratesForPreSetStatus() async {
        // A background check populates `status` (so the view's first-check path is
        // skipped). Opening the Updates screen calls `ensureChangelogSummary`,
        // which must generate the summary so it shows by default.
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.backgroundCheck()
        #expect(harness.status?.available == true)
        // Background check didn't summarize.
        #expect(harness.changelog == .idle)

        harness.ensureChangelogSummary()
        await harness.changelogTask?.value
        #expect(harness.changelog == .ready(.summary(headline: "H", highlights: ["a"])))
    }

    @Test
    func backgroundCheckPreservesExistingSummary() async {
        // A background tick on a still-available source update must not clobber a
        // summary already on screen (nor spin up the model).
        let runner = StubAdminRunner(checkResult("Update available: 122 commits behind origin/main."))
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        await harness.changelogTask?.value
        #expect(harness.changelog == .ready(.summary(headline: "H", highlights: ["a"])))

        await harness.backgroundCheck()
        await harness.changelogTask?.value
        #expect(harness.changelog == .ready(.summary(headline: "H", highlights: ["a"])))
        // The background tick never fetched or summarized.
        #expect(fetcher.callCount == 1)
        #expect(summarizer.callCount == 1)
    }

    @Test
    func backgroundUpToDateClearsStaleSummary() async {
        // But once the update is gone, a background "up to date" tick clears the
        // now-obsolete summary.
        let runner = StubAdminRunner([
            checkResult("Update available: 122 commits behind origin/main."),
            checkResult("Up to date with origin/main."),
        ])
        let fetcher = StubCommitFetcher([PendingCommit(subject: "x")])
        let summarizer = StubSummarizer(.summary(headline: "H", highlights: ["a"]))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder, fetcher: fetcher, summarizer: summarizer)

        await harness.check()
        await harness.changelogTask?.value
        #expect(harness.changelog == .ready(.summary(headline: "H", highlights: ["a"])))

        await harness.backgroundCheck()
        #expect(harness.changelog == .idle)
    }

    @Test
    func updateAvailableNotifiesOnce() async {
        let runner = StubAdminRunner(checkResult("Update available: 1.2.3 → 1.3.0"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(harness.status?.available == true)
        #expect(recorder.count == 1)
        // Checks no longer write to applyLog — that panel is reserved for actual
        // `hermes update` apply output.
        #expect(harness.applyLog.isEmpty)

        // Second check for the same version de-dupes the notify.
        await harness.backgroundCheck()
        #expect(recorder.count == 1)
        #expect(harness.applyLog.isEmpty)
    }

    @Test
    func newerVersionNotifiesAgain() async {
        let runner = StubAdminRunner([
            checkResult("Update available: 1.2.3 → 1.3.0"),
            checkResult("Update available: 1.2.3 → 1.4.0"),
        ])
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(recorder.count == 1)

        await harness.backgroundCheck()
        #expect(recorder.count == 2)
        #expect(recorder.last?.latest == HermesVersion(major: 1, minor: 4, patch: 0))
    }

    @Test
    func sourceInstallNotifiesOncePerAvailabilityStreak() async {
        // Source-install builds report a commits-behind count instead of a
        // version; the count drifts as upstream advances, but it's the same
        // un-applied update — notify once, not every interval.
        let runner = StubAdminRunner([
            checkResult("Update available: 122 commits behind origin/main."),
            checkResult("Update available: 130 commits behind origin/main."),
        ])
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(harness.status?.available == true)
        #expect(harness.status?.latest == nil)
        #expect(recorder.count == 1)

        await harness.backgroundCheck()
        #expect(recorder.count == 1)
    }

    @Test
    func reNotifiesAfterUpdateAppliedThenNewOneAppears() async {
        // available → up to date (applied) → available again should notify twice:
        // the "up to date" check resets the de-dupe state.
        let runner = StubAdminRunner([
            checkResult("Update available: 1.2.3 → 1.3.0"),
            checkResult("Up to date (1.3.0)"),
            checkResult("Update available: 1.3.0 → 1.4.0"),
        ])
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(recorder.count == 1)

        await harness.backgroundCheck() // up to date
        #expect(recorder.count == 1)

        await harness.backgroundCheck() // new update
        #expect(recorder.count == 2)
    }

    @Test
    func nonBackgroundUpToDateResetsDedupSoNextSourceUpdateNotifies() async {
        // The post-apply gap: after the user applies (a non-background check via
        // `check()` sees up to date), a genuinely new source update — which keys
        // on the constant "source-available" token — must notify again rather
        // than stay suppressed until the next background "up to date" tick.
        let runner = StubAdminRunner([
            checkResult("Update available: 122 commits behind origin/main."),
            checkResult("Up to date with origin/main."),
            checkResult("Update available: 130 commits behind origin/main."),
        ])
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(recorder.count == 1)

        // Manual check (stands in for the post-apply refresh) reports up to date.
        await harness.check()
        #expect(recorder.clearedCount == 1)

        await harness.backgroundCheck()
        #expect(recorder.count == 2)
    }

    @Test
    func upToDateNeverNotifies() async {
        let runner = StubAdminRunner(checkResult("Up to date (1.2.3)"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(harness.status?.available == false)
        #expect(recorder.count == 0)
        // Up to date clears the cross-window de-dupe.
        #expect(recorder.clearedCount == 1)
        // Checks don't write to the apply-output panel.
        #expect(harness.applyLog.isEmpty)
    }

    @Test
    func failingRunnerIsSilent() async {
        let runner = StubAdminRunner(.failure(StubError()))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(recorder.count == 0)
        #expect(harness.status == nil)
        // Background failures are silent — no banner-bound error surfaces.
        #expect(harness.lastError == nil)
    }

    @Test
    func skipsWhileApplying() async {
        let runner = StubAdminRunner(checkResult("Update available: 1.2.3 → 1.3.0"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)
        harness.isApplying = true

        await harness.backgroundCheck()
        #expect(runner.callCount == 0)
        #expect(harness.applyLog.isEmpty)
        #expect(recorder.count == 0)
    }

    @Test
    func skipsWhileAnotherWindowOnSameProfileIsApplying() async {
        // A background tick must not fire `hermes update --check` (a git fetch)
        // while another window is mid-apply on the same source-install repo.
        let runner = StubAdminRunner(checkResult("Update available: 1.2.3 → 1.3.0"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)
        harness.isProfileApplying = { true }

        await harness.backgroundCheck()
        #expect(runner.callCount == 0)
        #expect(harness.applyLog.isEmpty)
        #expect(recorder.count == 0)
    }

}

@MainActor
@Suite
struct UpdateApplyCoordinatorTests {
    @Test
    func refcountsOverlappingApplies() {
        // A fresh profile id so this never collides with a live window's state.
        let coordinator = UpdateApplyCoordinator.shared
        let profile = UUID()

        #expect(!coordinator.isApplying(profileId: profile))
        coordinator.setApplying(true, profileId: profile)
        coordinator.setApplying(true, profileId: profile)
        #expect(coordinator.isApplying(profileId: profile))

        // One of two overlapping applies finishing leaves the profile busy.
        coordinator.setApplying(false, profileId: profile)
        #expect(coordinator.isApplying(profileId: profile))

        coordinator.setApplying(false, profileId: profile)
        #expect(!coordinator.isApplying(profileId: profile))

        // Underflow is clamped, not negative.
        coordinator.setApplying(false, profileId: profile)
        #expect(!coordinator.isApplying(profileId: profile))
    }
}
