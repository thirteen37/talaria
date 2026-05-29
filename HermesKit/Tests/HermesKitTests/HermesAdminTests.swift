#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesAdminTests {
    @Test
    func localRunnerDrainsLargeStdoutAndStderr() async throws {
        let runner = LocalHermesAdminRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
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

    @Test
    func runStreamEmitsLinesAndExit() async throws {
        let runner = LocalHermesAdminRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let script = """
        echo "alpha"
        echo "beta"
        echo "gamma" 1>&2
        echo "delta"
        """

        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var exitCode: Int32?

        for try await event in runner.runStream(HermesAdminCommand(arguments: ["-c", script])) {
            switch event {
            case .stdoutLine(let line): stdoutLines.append(line)
            case .stderrLine(let line): stderrLines.append(line)
            case .exit(let code): exitCode = code
            }
        }

        #expect(stdoutLines == ["alpha", "beta", "delta"])
        #expect(stderrLines == ["gamma"])
        #expect(exitCode == 0)
    }

    @Test
    func runStreamHandlesLargeOutputOrderingAndLineBoundaries() async throws {
        let runner = LocalHermesAdminRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let script = """
        i=0
        while [ "$i" -lt 20000 ]; do
          echo "stdout-$i"
          echo "stderr-$i" 1>&2
          i=$((i + 1))
        done
        """

        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var sawExit = false
        var eventsAfterExit = 0

        for try await event in runner.runStream(HermesAdminCommand(arguments: ["-c", script])) {
            if sawExit { eventsAfterExit += 1 }
            switch event {
            case .stdoutLine(let line): stdoutLines.append(line)
            case .stderrLine(let line): stderrLines.append(line)
            case .exit(let code):
                #expect(code == 0)
                sawExit = true
            }
        }

        #expect(stdoutLines.count == 20_000)
        #expect(stderrLines.count == 20_000)
        #expect(stdoutLines.first == "stdout-0")
        #expect(stdoutLines.last == "stdout-19999")
        #expect(stderrLines.first == "stderr-0")
        #expect(stderrLines.last == "stderr-19999")
        #expect(sawExit)
        #expect(eventsAfterExit == 0, ".exit must be the final event")
    }

    @Test
    func runStreamEmitsTrailingPartialLineWithoutNewline() async throws {
        let runner = LocalHermesAdminRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        // printf without trailing newline — the final partial line still needs
        // to surface on stream termination.
        let script = #"printf "no-newline-here""#

        var stdoutLines: [String] = []
        for try await event in runner.runStream(HermesAdminCommand(arguments: ["-c", script])) {
            if case .stdoutLine(let line) = event { stdoutLines.append(line) }
        }
        #expect(stdoutLines == ["no-newline-here"])
    }

    @Test
    func runStreamCancellationTerminatesChild() async throws {
        let runner = LocalHermesAdminRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        // Long-running emitter: prints a line per 50ms forever.
        let script = """
        while true; do
          echo "tick"
          sleep 0.05
        done
        """

        let stream = runner.runStream(HermesAdminCommand(arguments: ["-c", script]))
        var pulled = 0
        for try await event in stream {
            if case .stdoutLine = event { pulled += 1 }
            if pulled == 3 { break }
        }
        #expect(pulled == 3)
    }
}
#endif
