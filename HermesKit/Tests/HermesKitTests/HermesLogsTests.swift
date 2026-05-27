import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesLogsTests {
    @Test
    func parsesStructuredLine() {
        let raw = "[2026-05-23T12:34:56Z] [INFO ] daemon: started worker pool"
        let line = HermesLogs.parse(raw)
        #expect(line.level == .info)
        #expect(line.component == "daemon")
        #expect(line.message == "started worker pool")
        #expect(line.timestamp != nil)
        #expect(line.raw == raw)
    }

    @Test
    func parsesAllKnownLevels() {
        let cases: [(String, LogLevel)] = [
            ("[ts] [DEBUG] c: m", .debug),
            ("[ts] [INFO ] c: m", .info),
            ("[ts] [WARN ] c: m", .warn),
            ("[ts] [ERROR] c: m", .error),
            ("[ts] [FATAL] c: m", .error),
        ]
        for (raw, expected) in cases {
            let line = HermesLogs.parse(raw)
            #expect(line.level == expected, "expected \(expected) for \(raw)")
        }
    }

    @Test
    func fallsBackToUnknownForUnstructuredLine() {
        let raw = "Traceback (most recent call last):"
        let line = HermesLogs.parse(raw)
        #expect(line.level == .unknown)
        #expect(line.component == "")
        #expect(line.message == raw)
    }

    @Test
    func toleratesMissingComponent() {
        let raw = "[2026-05-23T12:34:56Z] [INFO ] message-without-colon"
        let line = HermesLogs.parse(raw)
        #expect(line.level == .info)
        #expect(line.component == "")
        #expect(line.message == "message-without-colon")
    }

    @Test
    func parsesPythonLoggingFormatWithoutBrackets() {
        // The real hermes agent.log lines look like:
        //   `2026-05-24 15:18:06,289 INFO hermes_cli.plugins: msg`
        // Before this fix the parser required `[ts] [LEVEL]` brackets, so
        // every line in the logs view came back as level=.unknown,
        // component="".
        let raw = "2026-05-24 15:18:06,289 INFO hermes_cli.plugins: Plugin discovery complete: 27 found, 23 enabled"
        let line = HermesLogs.parse(raw)
        #expect(line.level == .info)
        #expect(line.component == "hermes_cli.plugins")
        #expect(line.message == "Plugin discovery complete: 27 found, 23 enabled")
        #expect(line.timestamp != nil)
    }

    @Test
    func parsesPythonLoggingWithSessionIDBracket() {
        // errors.log adds a `[session-uuid]` between LEVEL and component.
        let raw = "2026-05-23 14:16:55,994 ERROR [ca17a751-0682-4e38-a2dd-2988bc0455f0] root: API call failed after 3 retries."
        let line = HermesLogs.parse(raw)
        #expect(line.level == .error)
        #expect(line.component == "root")
        #expect(line.message == "API call failed after 3 retries.")
    }

#if os(macOS)
    @Test
    func remoteLogTailingAcceptsNilHermesHome() {
        // Pre-change, RemoteLogTailing required a literal hermesHome at
        // construction. The Logs view now hands it `profile.hermesHome` —
        // possibly nil — and the tailer is expected to resolve at tail()
        // time. Locking in that nil construction is supported keeps the
        // makeTailing factory from regressing to returning nil for SSH
        // profiles that haven't been configured with HERMES_HOME.
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "example.com"
        )
        let tailing = RemoteLogTailing(profile: profile, hermesHome: nil)
        #expect(tailing.hermesHome == nil)
        // Default-argument form must also compile — that's the call site
        // the LogsView uses.
        let defaulted = RemoteLogTailing(profile: profile)
        #expect(defaulted.hermesHome == nil)
    }

    @Test
    func resolveHermesHomeShortCircuitsAbsolutePaths() async throws {
        // Absolute literal paths don't need a remote round trip. The
        // resolveHermesHome fast path returns them verbatim so the Logs view
        // can start tailing without paying for an extra ssh probe — and so
        // tests can exercise the path without a live remote.
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "example.com"
        )
        let resolved = try await RemoteLogTailing.resolveHermesHome(
            profile: profile,
            hermesHome: "/var/hermes"
        )
        #expect(resolved == "/var/hermes")
    }

    @Test
    func localLogTailingPicksUpAppends() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hermes-logs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let logsDir = temp.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let file = logsDir.appendingPathComponent("daemon.log")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let tailing = LocalLogTailing(hermesHome: temp.path, pollInterval: 0.05)
        let stream = tailing.tail(component: nil)

        // Spin up reader
        let collected: Task<[LogLine], Error> = Task {
            var out: [LogLine] = []
            for try await line in stream {
                out.append(line)
                if out.count >= 2 { break }
            }
            return out
        }

        // Give the tailer time to do its initial scan and reach EOF.
        try await Task.sleep(nanoseconds: 200_000_000)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-05-23T00:00:00Z] [INFO ] daemon: hello\n".utf8))
        try handle.write(contentsOf: Data("[2026-05-23T00:00:01Z] [WARN ] daemon: heads up\n".utf8))
        try handle.close()

        let lines = try await collected.value
        #expect(lines.count == 2)
        #expect(lines[0].level == .info)
        #expect(lines[0].message == "hello")
        #expect(lines[1].level == .warn)

        try? FileManager.default.removeItem(at: temp)
    }
#endif
}
