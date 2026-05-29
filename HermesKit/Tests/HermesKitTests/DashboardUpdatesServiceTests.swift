import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardUpdatesServiceTests {
    @Test
    func currentStateReadsFromStatus() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/status", body: try loadFixture("status.json"))
        ])
        let service = makeService(http: http, pollInterval: 0.001)

        let state = try await service.currentState()

        #expect(state.version == "0.14.0")
        #expect(state.releaseDate == "2026.5.16")
    }

    @Test
    func applyEmitsNewLinesAndFinishesWhenRunningFlipsToFalse() async throws {
        let http = StubHTTP(responses: [
            // Pre-start snapshot: empty buffer, so seenLineCount starts at 0.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":null,"pid":null,"lines":[]}"#.utf8)),
            // POST to start
            .init(path: "/api/hermes/update", body: Data("{}".utf8)),
            // First poll: running, two lines
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":true,"exit_code":null,"pid":1,"lines":["fetching\n","applying\n"]}"#.utf8)),
            // Second poll: still running, one more line
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":true,"exit_code":null,"pid":1,"lines":["fetching\n","applying\n","linking\n"]}"#.utf8)),
            // Third poll: done
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":1,"lines":["fetching\n","applying\n","linking\n","done\n"]}"#.utf8)),
        ])
        let service = makeService(http: http, pollInterval: 0.001)

        var batches: [[String]] = []
        var exitCode: Int32? = nil
        for try await event in service.apply() {
            switch event {
            case .logLines(let lines): batches.append(lines)
            case .finished(let code): exitCode = code
            }
        }

        #expect(batches.count == 3)
        #expect(batches[0] == ["fetching\n", "applying\n"])
        #expect(batches[1] == ["linking\n"])
        #expect(batches[2] == ["done\n"])
        #expect(exitCode == 0)
    }

    @Test
    func applyDoesNotReplayLinesLeftFromAPreviousRun() async throws {
        // The action buffer still holds two lines from a prior update when
        // apply() starts. Those must NOT be re-emitted — only lines produced
        // after the trigger should surface.
        let http = StubHTTP(responses: [
            // Pre-start snapshot: two stale lines.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":["old-1\n","old-2\n"]}"#.utf8)),
            // POST to start
            .init(path: "/api/hermes/update", body: Data("{}".utf8)),
            // First poll: stale lines plus one genuinely new line.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":true,"exit_code":null,"pid":1,"lines":["old-1\n","old-2\n","new-1\n"]}"#.utf8)),
            // Second poll: done.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":1,"lines":["old-1\n","old-2\n","new-1\n","new-2\n"]}"#.utf8)),
        ])
        let service = makeService(http: http, pollInterval: 0.001)

        var emitted: [String] = []
        for try await event in service.apply() {
            if case .logLines(let lines) = event { emitted.append(contentsOf: lines) }
        }

        #expect(emitted == ["new-1\n", "new-2\n"])
    }

    @Test
    func applyWaitsForRunningBeforeTreatingNotRunningAsDone() async throws {
        // The dashboard hasn't flipped `running` to true yet when the first
        // poll lands after the trigger — it still reports the *previous* run's
        // terminal state (running:false, exit 0, stale buffer). The stream must
        // NOT finish here; it should keep polling until the real run starts and
        // then completes, tailing only the new run's output.
        let http = StubHTTP(responses: [
            // Pre-start snapshot: a prior run's terminal state.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":1,"lines":["old\n"]}"#.utf8)),
            // POST to start.
            .init(path: "/api/hermes/update", body: Data("{}".utf8)),
            // First poll: run hasn't started yet — still the stale terminal state.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":1,"lines":["old\n"]}"#.utf8)),
            // Second poll: the run is now active and producing output.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":true,"exit_code":null,"pid":2,"lines":["old\n","step1\n"]}"#.utf8)),
            // Third poll: real completion.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":2,"lines":["old\n","step1\n","done\n"]}"#.utf8)),
        ])
        let service = makeService(http: http, pollInterval: 0.001)

        var emitted: [String] = []
        var exitCode: Int32? = nil
        for try await event in service.apply() {
            switch event {
            case .logLines(let lines): emitted.append(contentsOf: lines)
            case .finished(let code): exitCode = code
            }
        }

        // Only the new run's lines — proves we didn't finish on the stale poll.
        #expect(emitted == ["step1\n", "done\n"])
        #expect(exitCode == 0)
    }

    @Test
    func applyFinishesAfterStartupGraceWhenRunNeverStarts() async throws {
        // The run never flips `running` true (instant no-op, or the dashboard
        // never starts it). The stream must not hang: after the startup grace
        // it finishes rather than polling forever.
        let http = StubHTTP(responses: [
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":[]}"#.utf8)),
            .init(path: "/api/hermes/update", body: Data("{}".utf8)),
            // Not-running polls until the 0.003s grace at 0.001s interval
            // expires (~3 polls). One extra is provided so a float-rounding
            // off-by-one can't exhaust the stub before the loop finishes;
            // StubHTTP doesn't require every response to be consumed.
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":[]}"#.utf8)),
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":[]}"#.utf8)),
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":[]}"#.utf8)),
            .init(path: "/api/actions/hermes-update/status",
                  body: Data(#"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":[]}"#.utf8)),
        ])
        let service = DashboardUpdatesService(
            client: DashboardClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: { "tok" }, http: http),
            pollInterval: 0.001,
            startupGrace: 0.003
        )

        var emitted: [String] = []
        var finished = false
        for try await event in service.apply() {
            switch event {
            case .logLines(let lines): emitted.append(contentsOf: lines)
            case .finished: finished = true
            }
        }

        #expect(emitted.isEmpty)
        #expect(finished)
    }

    private func makeService(http: StubHTTP, pollInterval: TimeInterval) -> DashboardUpdatesService {
        let client = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
        return DashboardUpdatesService(client: client, pollInterval: pollInterval)
    }

    private func loadFixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Dashboard")
        )
        return try Data(contentsOf: url)
    }
}
