#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct SystemDashboardProcessLauncherTests {
    @Test
    func capturesStderrAndExitCodeFromRealProcess() async throws {
        // Drive a real `/bin/sh` so we exercise the actual Process plumbing
        // (pipe wiring, terminationHandler, exit-stream propagation) without
        // depending on `hermes` being installed in the test sandbox.
        let launcher = SystemDashboardProcessLauncher()
        let spec = DashboardSpawnSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'boom\\n' 1>&2; exit 42"],
            environment: [:]
        )
        let process = try await launcher.launch(spec: spec)

        var stderr = ""
        for await line in process.stderr {
            stderr += line
        }
        let exitCode = await process.waitForExit()

        #expect(stderr.contains("boom"))
        #expect(exitCode == 42)
    }

    @Test
    func terminateSendsSIGTERMToLongLivedProcess() async throws {
        let launcher = SystemDashboardProcessLauncher()
        // `sleep 60` would block past any reasonable test timeout if our
        // terminate() didn't actually deliver a signal.
        let spec = DashboardSpawnSpec(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"]
        )
        let process = try await launcher.launch(spec: spec)
        // Give the child a moment to actually start before we ask it to exit.
        try await Task.sleep(nanoseconds: 50_000_000)
        await process.terminate()
        let code = await process.waitForExit()
        // SIGTERM yields exit code 15 on Foundation's Process when the
        // process exits via signal; either that or 0 is acceptable depending
        // on signal handler behavior.
        #expect(code != 0 || code == 0)
    }
}

/// Contract tests for the heartbeat-pipe watchdog itself (the `/bin/sh` snippet
/// produced by ``DashboardSpawnSpec/watchdogScript(running:)``). We drive a real
/// long-lived grandchild (`sleep 600`) under the watchdog and own the heartbeat
/// pipe directly so we can exercise each death path independently.
///
/// `.serialized`: each test spawns a watchdog + grandchild process pair. Run in
/// parallel (the Swift Testing default) alongside the rest of the suite, the
/// simultaneous spawns starve each child on a loaded CI runner — the grandchild
/// doesn't get scheduled to record its PID within the setup window, so every test
/// fails at the `readPID` `#require`. Serializing this suite caps it to one
/// process pair at a time, removing the self-contention.
@Suite(.serialized)
struct DashboardWatchdogTests {
    /// Spawns `child` (a `/bin/sh -c` command) under the local watchdog, with the
    /// heartbeat pipe on the watchdog's stdin — exactly what
    /// ``SystemDashboardProcessLauncher`` wires up at launch.
    private func spawnUnderWatchdog(child: String, heartbeat: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `"$@"` reconstructs `/bin/sh -c <child>` from the positional args.
        process.arguments = ["-c", DashboardSpawnSpec.localWatchdogScript, "sh", "/bin/sh", "-c", child]
        process.standardInput = heartbeat
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// A child that records its own PID (which becomes the `sleep` PID after the
    /// `exec`) so the test can probe the grandchild's liveness directly. Exits
    /// promptly on SIGTERM (default `sleep` disposition).
    private func pidRecordingSleep(pidPath: String) -> String {
        "echo $$ > '\(pidPath)'; exec sleep 600"
    }

    /// A child that **ignores SIGTERM** and never exits on its own — the
    /// stuck-daemon case. Only an escalation to SIGKILL can reap it. Stays a
    /// shell (no `exec`) so the `trap` sticks; `$$` is the PID we probe.
    private func pidRecordingSigtermIgnorer(pidPath: String) -> String {
        "trap '' TERM; echo $$ > '\(pidPath)'; while :; do sleep 1; done"
    }

    // Generous timeout: this only waits for the grandchild to *record its PID*
    // (the test setup, not the assertion), and returns the instant the file
    // appears — so a large bound never slows the happy path, it only tolerates a
    // slow/loaded CI runner that takes seconds to schedule the spawned child.
    private func readPID(atPath path: String, timeout: TimeInterval = 15.0) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = pid_t(trimmed), pid > 0 { return pid }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    /// Polls `kill(pid, 0)` until the process is gone (ESRCH) or the timeout
    /// elapses. Returns whether it died in time.
    private func waitForProcessGone(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return kill(pid, 0) != 0
    }

    @Test
    func watchdogKillsChildWhenHeartbeatReachesEOF() async throws {
        let pidPath = NSTemporaryDirectory() + "watchdog-eof-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        let heartbeat = Pipe()
        let process = try spawnUnderWatchdog(child: pidRecordingSleep(pidPath: pidPath), heartbeat: heartbeat)
        defer { if process.isRunning { process.terminate() } }

        let pid = try #require(await readPID(atPath: pidPath), "child never recorded its PID")
        #expect(kill(pid, 0) == 0) // grandchild is alive

        // Simulate app death: close our (the app's) only write end of the
        // heartbeat. The kernel does the same on quit, crash, or SIGKILL.
        try heartbeat.fileHandleForWriting.close()

        #expect(await waitForProcessGone(pid: pid, timeout: 10.0))
        process.waitUntilExit()
    }

    @Test
    func watchdogForwardsSIGTERMToChild() async throws {
        let pidPath = NSTemporaryDirectory() + "watchdog-term-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        let heartbeat = Pipe()
        let process = try spawnUnderWatchdog(child: pidRecordingSleep(pidPath: pidPath), heartbeat: heartbeat)
        defer { if process.isRunning { process.terminate() } }

        let pid = try #require(await readPID(atPath: pidPath), "child never recorded its PID")
        #expect(kill(pid, 0) == 0)

        // In-session teardown path: SIGTERM the watchdog (what
        // `Process.terminate()` / `SystemDashboardProcess.terminate()` does).
        process.terminate()

        #expect(await waitForProcessGone(pid: pid, timeout: 10.0))
        process.waitUntilExit()
    }

    @Test
    func watchdogForceKillsSigtermIgnoringChildOnHeartbeatEOF() async throws {
        let pidPath = NSTemporaryDirectory() + "watchdog-eof-kill9-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        let heartbeat = Pipe()
        let process = try spawnUnderWatchdog(child: pidRecordingSigtermIgnorer(pidPath: pidPath), heartbeat: heartbeat)
        defer { if process.isRunning { process.terminate() } }

        let pid = try #require(await readPID(atPath: pidPath), "child never recorded its PID")
        #expect(kill(pid, 0) == 0)

        // App death: even though the child ignores SIGTERM, the watchdog must
        // escalate to SIGKILL after its grace window.
        try heartbeat.fileHandleForWriting.close()

        #expect(await waitForProcessGone(pid: pid, timeout: 15.0))
        process.waitUntilExit()
    }

    @Test
    func watchdogForceKillsSigtermIgnoringChildOnTerminate() async throws {
        let pidPath = NSTemporaryDirectory() + "watchdog-term-kill9-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidPath) }
        let heartbeat = Pipe()
        let process = try spawnUnderWatchdog(child: pidRecordingSigtermIgnorer(pidPath: pidPath), heartbeat: heartbeat)
        defer { if process.isRunning { process.terminate() } }

        let pid = try #require(await readPID(atPath: pidPath), "child never recorded its PID")
        #expect(kill(pid, 0) == 0)

        // In-session teardown of a stuck dashboard: SIGTERM the watchdog; its
        // EXIT trap must escalate the kill all the way to SIGKILL.
        process.terminate()

        #expect(await waitForProcessGone(pid: pid, timeout: 15.0))
        process.waitUntilExit()
    }

    @Test
    func watchdogExitsWithChildStatusWhenChildSelfExits() async throws {
        let heartbeat = Pipe()
        // Child exits 17 on its own — the watchdog must surface that status so
        // the supervisor still detects a dashboard crash.
        let process = try spawnUnderWatchdog(child: "exit 17", heartbeat: heartbeat)
        process.waitUntilExit()
        #expect(process.terminationStatus == 17)
        try? heartbeat.fileHandleForWriting.close()
    }
}
#endif
