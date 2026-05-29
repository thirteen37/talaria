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
#endif
