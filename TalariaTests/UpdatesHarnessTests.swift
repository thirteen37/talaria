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
    private func makeHarness(_ runner: HermesAdminRunning?, recorder: NotifyRecorder) -> UpdatesHarness {
        let harness = UpdatesHarness(runner: runner)
        harness.onUpdateAvailable = { status in recorder.record(status) }
        harness.onUpdateCleared = { recorder.recordCleared() }
        return harness
    }

    @Test
    func updateAvailableNotifiesOnceAndLogs() async {
        let runner = StubAdminRunner(checkResult("Update available: 1.2.3 → 1.3.0"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(harness.status?.available == true)
        #expect(recorder.count == 1)
        #expect(harness.applyLog.count == 1)

        // Second check for the same version: still logs, but de-dupes the notify.
        await harness.backgroundCheck()
        #expect(recorder.count == 1)
        #expect(harness.applyLog.count == 2)
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
    func upToDateNeverNotifiesButLogs() async {
        let runner = StubAdminRunner(checkResult("Up to date (1.2.3)"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)

        await harness.backgroundCheck()
        #expect(harness.status?.available == false)
        #expect(recorder.count == 0)
        // Up to date clears the cross-window de-dupe.
        #expect(recorder.clearedCount == 1)
        #expect(harness.applyLog.count == 1)
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
    func skipsWhileChecking() async {
        let runner = StubAdminRunner(checkResult("Update available: 1.2.3 → 1.3.0"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)
        harness.isChecking = true

        await harness.backgroundCheck()
        #expect(runner.callCount == 0)
        #expect(harness.applyLog.isEmpty)
        #expect(recorder.count == 0)
    }

    @Test
    func manualCheckSkipsWhileAnotherCheckRuns() async {
        // A manual check must not race an in-flight check (the view's `.task`
        // can fire it while the background loop's first check is still running).
        let runner = StubAdminRunner(checkResult("Up to date (1.2.3)"))
        let recorder = NotifyRecorder()
        let harness = makeHarness(runner, recorder: recorder)
        harness.isChecking = true

        await harness.check()
        #expect(runner.callCount == 0)
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

    @Test
    func nilRunnerIsNoOp() async {
        let recorder = NotifyRecorder()
        let harness = makeHarness(nil, recorder: recorder)

        await harness.backgroundCheck()
        #expect(harness.status == nil)
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
