import Foundation

public struct DashboardUpdateState: Sendable, Equatable {
    public let version: String
    public let releaseDate: String?

    public init(version: String, releaseDate: String?) {
        self.version = version
        self.releaseDate = releaseDate
    }
}

public enum DashboardUpdateEvent: Sendable, Equatable {
    /// One or more new log lines from `/api/actions/hermes-update/status`.
    case logLines([String])
    /// Update completed (running flipped to `false`) with the action's exit
    /// code if any was captured.
    case finished(exitCode: Int32?)
}

/// Drives the dashboard's `POST /api/hermes/update` → polled
/// `GET /api/actions/hermes-update/status` flow.
///
/// Why polling instead of streaming: the dashboard's action surface is a
/// per-action "tail" endpoint that returns the full line buffer on each
/// hit. We sample it on a short interval and emit only the new tail; the
/// view sees a stream of `AdminEvent`-shaped values without the underlying
/// long-poll/WebSocket plumbing.
public struct DashboardUpdatesService: Sendable {
    private let client: DashboardClient
    private let pollInterval: TimeInterval
    private let startupGrace: TimeInterval

    public init(client: DashboardClient, pollInterval: TimeInterval = 0.5, startupGrace: TimeInterval = 5.0) {
        self.client = client
        self.pollInterval = pollInterval
        self.startupGrace = startupGrace
    }

    public func currentState() async throws -> DashboardUpdateState {
        let status = try await client.getStatus()
        return DashboardUpdateState(version: status.version, releaseDate: status.releaseDate)
    }

    /// Kicks off `POST /api/hermes/update` and emits every new log line
    /// observed at `/api/actions/hermes-update/status` until `running`
    /// flips to `false`. Cancelling the awaiter aborts the poll loop; the
    /// dashboard's action keeps running on the host until it finishes
    /// (intentional — partial-rollback is upstream's problem, not Talaria's).
    public func apply() -> AsyncThrowingStream<DashboardUpdateEvent, Error> {
        let client = client
        let pollInterval = pollInterval
        let startupGrace = startupGrace
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Seed from the pre-start tail so a previous run's leftover
                    // lines aren't replayed as if they belonged to this run.
                    // Diff against the previous full snapshot rather than a fixed
                    // offset: `POST /api/hermes/update` may either append to the
                    // existing buffer or reset it for the new run. `TailDiff`
                    // handles both — a reset shows up as no overlap and emits the
                    // new run's lines from the start instead of stalling until
                    // the line count climbs past the old total.
                    var previousLines = (try? await client.getUpdateActionStatus())?.lines ?? []
                    try await client.startHermesUpdate()
                    // The dashboard may not flip `running` to true before the
                    // POST returns — a background task can start the run a moment
                    // later. Treating the first observed `running: false` as
                    // completion would end the stream on the *previous* run's
                    // terminal state with its stale exit code. So require one
                    // `running: true` observation before `false` counts as done.
                    // The startup grace bounds that wait so a fast or no-op run
                    // (that we never catch as running) can't hang the stream.
                    var observedRunning = false
                    var startupPollsRemaining = max(1, Int((startupGrace / pollInterval).rounded(.up)))
                    while !Task.isCancelled {
                        let status = try await client.getUpdateActionStatus()
                        let newLines = TailDiff.newSuffix(of: status.lines, after: previousLines)
                        if !newLines.isEmpty {
                            continuation.yield(.logLines(newLines))
                        }
                        previousLines = status.lines

                        if status.running {
                            observedRunning = true
                        } else if observedRunning {
                            // Saw the run active, now idle — genuine completion.
                            continuation.yield(.finished(exitCode: status.exitCode.map { Int32($0) }))
                            continuation.finish()
                            return
                        } else {
                            // Still in the pre-start window; keep waiting for the
                            // run to flip `running` true, up to the startup grace.
                            startupPollsRemaining -= 1
                            if startupPollsRemaining <= 0 {
                                continuation.yield(.finished(exitCode: status.exitCode.map { Int32($0) }))
                                continuation.finish()
                                return
                            }
                        }
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
