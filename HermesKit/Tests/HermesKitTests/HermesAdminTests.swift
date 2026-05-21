#if os(macOS)
import Testing
@testable import HermesKit

@Suite
struct HermesAdminTests {
    @Test
    func localRunnerDrainsLargeStdoutAndStderr() async throws {
        let runner = LocalHermesAdminRunner(hermesPath: "/bin/sh")
        let expectedStdout = (0..<20_000).map { "stdout-\($0)" }.joined(separator: "\n") + "\n"
        let expectedStderr = (0..<20_000).map { "stderr-\($0)" }.joined(separator: "\n") + "\n"
        let script = """
        i=0
        while [ "$i" -lt 20000 ]; do
          echo "stdout-$i"
          echo "stderr-$i" 1>&2
          i=$((i + 1))
        done
        """

        let result = try await runner.run(HermesAdminCommand(arguments: ["-c", script]))

        #expect(result.exitCode == 0)
        #expect(result.stdout == expectedStdout)
        #expect(result.stderr == expectedStderr)
    }
}
#endif
