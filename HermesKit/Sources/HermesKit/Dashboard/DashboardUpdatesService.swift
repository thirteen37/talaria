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

    public init(client: DashboardClient, pollInterval: TimeInterval = 0.5) {
        self.client = client
        self.pollInterval = pollInterval
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Seed from the pre-start tail so a previous run's leftover
                    // lines aren't replayed as if they belonged to this run —
                    // `POST /api/hermes/update` doesn't necessarily clear the
                    // action buffer. Best-effort: if the pre-start probe fails
                    // we start from 0 and accept the (rare) replay rather than
                    // aborting the update.
                    var seenLineCount = (try? await client.getUpdateActionStatus())?.lines.count ?? 0
                    try await client.startHermesUpdate()
                    while !Task.isCancelled {
                        let status = try await client.getUpdateActionStatus()
                        let newLines = Array(status.lines.dropFirst(seenLineCount))
                        if !newLines.isEmpty {
                            continuation.yield(.logLines(newLines))
                            seenLineCount = status.lines.count
                        }
                        if !status.running {
                            let code = status.exitCode.map { Int32($0) }
                            continuation.yield(.finished(exitCode: code))
                            continuation.finish()
                            return
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
