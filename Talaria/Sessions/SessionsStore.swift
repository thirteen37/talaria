import Foundation
import HermesKit
import SwiftUI

@MainActor
@Observable
final class SessionsStore {
    struct OpenSession: Identifiable, Equatable {
        var id: SessionId
        var cwd: String
        var title: String?
    }

    enum Status: Equatable {
        case idle
        case working
        case error(String)
    }

    var openSessions: [OpenSession] = []
    var selection: SessionId?
    var statuses: [SessionId: Status] = [:]
    var lastError: String?
    var browserRefreshToken: Int = 0
    /// True while a session open (new or resume) is in flight, so the UI can
    /// disable "New session" and show a connecting indicator. Tracked as a
    /// count to stay correct if opens overlap.
    var isOpening: Bool { openingCount > 0 }
    private var openingCount = 0

    let manager: SessionManager
    let adminRunner: HermesAdminRunning?
    let snapshot: RemoteSnapshot?
    let defaultCwd: String

    private var statusTasks: [SessionId: Task<Void, Never>] = [:]
    private var viewModels: [SessionId: LocalChatViewModel] = [:]
    private var pendingOpens: Set<SessionId> = []
    /// Per-session map from `toolCallId` → declared `kind`. ACP sets `kind`
    /// on the initial `tool_call` event but typically omits it on the
    /// follow-up `tool_call_update` events; we look up the original kind to
    /// decide whether a completion should invalidate the snapshot.
    private var toolKinds: [SessionId: [ToolCallId: ToolKind]] = [:]
    private let cwdStore: SessionsCwdStore
    /// Returns true while the open is blocked on interactive user input (the
    /// host-key trust prompt). The open timeout pauses while this is true so
    /// a slow fingerprint comparison doesn't trip the "handshake" deadline.
    private let isAwaitingUserInput: @MainActor @Sendable () -> Bool

    init(
        manager: SessionManager,
        adminRunner: HermesAdminRunning? = nil,
        snapshot: RemoteSnapshot? = nil,
        defaultCwd: String = SessionsStore.defaultHomeDirectory(),
        cwdStore: SessionsCwdStore = SessionsCwdStore(),
        isAwaitingUserInput: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.manager = manager
        self.adminRunner = adminRunner
        self.snapshot = snapshot
        self.defaultCwd = defaultCwd
        self.cwdStore = cwdStore
        self.isAwaitingUserInput = isAwaitingUserInput
    }

    /// `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS — the
    /// app sandbox makes a per-user home meaningless there. iOS is remote-only,
    /// so the cwd lives on the remote host: returning `"~"` lets the remote
    /// shell expand it to whichever home the SSH login lands in, rather than
    /// shipping a local sandbox path the remote can't `cd` into.
    static func defaultHomeDirectory() -> String {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.path
        #else
        return "~"
        #endif
    }

    /// Upper bound on opening a session. The SSH connect already has its own
    /// 15s bound, but the ACP `initialize` + `session/new` round-trips that
    /// follow have none — a host that accepts the connection but never speaks
    /// ACP (wrong binary, `hermes acp` wedged) would otherwise hang `openNew`
    /// forever with no error surfaced. 30s covers a slow login shell sourcing
    /// heavy rc files plus the handshake.
    static let openTimeout: TimeInterval = 30

    func openNew(cwd: String? = nil) async {
        let workingDir = cwd ?? defaultCwd
        AppLog.session.info("openNew: begin cwd=\(workingDir, privacy: .public)")
        openingCount += 1
        defer { openingCount -= 1 }
        do {
            let state = try await Self.withTimeout(Self.openTimeout, isPaused: isAwaitingUserInput) {
                try await self.manager.openNew(cwd: workingDir)
            }
            cwdStore.record(id: state.id, cwd: state.cwd)
            insert(OpenSession(id: state.id, cwd: state.cwd, title: nil))
            selection = state.id
            attachStatus(id: state.id)
            await ensureViewModel(id: state.id, cwd: state.cwd)
            AppLog.session.info("openNew: ready id=\(state.id, privacy: .public)")
        } catch {
            AppLog.session.error("openNew: failed: \(String(describing: error), privacy: .public)")
            lastError = Self.describe(error)
        }
    }

    /// Human-readable text for connection/session errors. Prefers our typed
    /// `LocalizedError` descriptions over Foundation's opaque
    /// "operation couldn't be completed (… error N)".
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    /// Races `operation` against a timeout. On expiry the operation task is
    /// cancelled (HermesClient's request path honors cancellation) and a
    /// descriptive error is thrown so the UI shows something actionable
    /// instead of spinning silently.
    ///
    /// `isPaused` lets the deadline stop advancing while the open is blocked on
    /// interactive input (the host-key trust prompt) — otherwise a user who
    /// takes >`seconds` to compare a fingerprint would trip the timeout and
    /// tear down a connection they're about to trust.
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        isPaused: @escaping @MainActor @Sendable () -> Bool = { false },
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let tick: TimeInterval = 0.25
                var remaining = seconds
                while remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                    // Don't count time spent waiting on the user's trust
                    // decision — that's interactive wait, not a stalled host.
                    if await isPaused() { continue }
                    remaining -= tick
                }
                throw TransportError.processDidNotStart(
                    "Connected, but the server didn't complete the Hermes handshake within \(Int(seconds))s. "
                    + "Check that `hermes acp` runs on the server for this profile's shell."
                )
            }
            defer { group.cancelAll() }
            // First task to finish wins; cancel the rest.
            return try await group.next()!
        }
    }

    func openExisting(_ summary: HermesSessionSummary) async {
        // Either already open or being opened concurrently — treat a second
        // tap as a benign "switch to it once it exists" intent instead of
        // racing through manager.openExisting and surfacing duplicateSession
        // as an error toast.
        if openSessions.contains(where: { $0.id == summary.id }) || pendingOpens.contains(summary.id) {
            selection = summary.id
            return
        }
        pendingOpens.insert(summary.id)
        openingCount += 1
        defer {
            pendingOpens.remove(summary.id)
            openingCount -= 1
        }

        let workingDir = cwdStore.cwd(for: summary.id) ?? summary.cwd ?? defaultCwd
        do {
            let state = try await Self.withTimeout(Self.openTimeout, isPaused: isAwaitingUserInput) {
                try await self.manager.openExisting(id: summary.id, cwd: workingDir)
            }
            cwdStore.record(id: state.id, cwd: state.cwd)
            insert(OpenSession(id: state.id, cwd: state.cwd, title: summary.title))
            selection = state.id
            attachStatus(id: state.id)
            await ensureViewModel(id: state.id, cwd: state.cwd)
        } catch SessionManagerError.duplicateSession {
            // A concurrent caller registered first; just focus the session.
            selection = summary.id
        } catch {
            AppLog.session.error("openExisting: failed: \(String(describing: error), privacy: .public)")
            lastError = Self.describe(error)
        }
    }

    func viewModel(for id: SessionId) -> LocalChatViewModel? {
        viewModels[id]
    }

    private func ensureViewModel(id: SessionId, cwd: String) async {
        if viewModels[id] != nil {
            return
        }
        let vm = LocalChatViewModel(manager: manager, sessionId: id, cwd: cwd, store: self)
        viewModels[id] = vm
        await vm.start()
    }

    func closeTab(_ id: SessionId) async {
        statusTasks[id]?.cancel()
        statusTasks[id] = nil
        statuses[id] = nil
        toolKinds.removeValue(forKey: id)
        openSessions.removeAll { $0.id == id }
        if selection == id {
            selection = openSessions.first?.id
        }
        if let vm = viewModels.removeValue(forKey: id) {
            await vm.shutdown()
        }
        await manager.close(id: id)
    }

    func renameSession(_ id: SessionId, to title: String) async {
        guard let adminRunner else {
            lastError = "Hermes admin not configured"
            return
        }
        do {
            let result = try await adminRunner.renameSession(id, to: title)
            if result.exitCode != 0 {
                lastError = result.stderr.isEmpty ? "hermes sessions rename exited \(result.exitCode)" : result.stderr
                return
            }
            if let index = openSessions.firstIndex(where: { $0.id == id }) {
                openSessions[index].title = title
            }
            browserRefreshToken &+= 1
            if let snapshot {
                await snapshot.invalidate()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteSession(_ id: SessionId) async {
        guard let adminRunner else {
            lastError = "Hermes admin not configured"
            return
        }
        // Tear down our ACP session first so the running `hermes acp` process
        // releases its writer on state.db before the CLI delete subprocess
        // touches the same rows. Running both in parallel can produce FK
        // errors or orphan messages depending on upstream schema.
        await closeTab(id)
        do {
            let result = try await adminRunner.deleteSession(id)
            if result.exitCode != 0 {
                lastError = result.stderr.isEmpty ? "hermes sessions delete exited \(result.exitCode)" : result.stderr
                return
            }
            cwdStore.forget(id: id)
            browserRefreshToken &+= 1
            if let snapshot {
                await snapshot.invalidate()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func insert(_ session: OpenSession) {
        if let index = openSessions.firstIndex(where: { $0.id == session.id }) {
            openSessions[index] = session
        } else {
            openSessions.append(session)
        }
    }

    private func attachStatus(id: SessionId) {
        statusTasks[id]?.cancel()
        statuses[id] = .idle

        let stream = Task { await manager.notifications(for: id) }
        statusTasks[id] = Task { [weak self] in
            let asyncStream = await stream.value
            for await notification in asyncStream {
                self?.observe(id: id, notification: notification)
            }
            // Skip the post-stream idle reset when cancelled — a restart of
            // attachStatus on the same id has already replaced this task, and
            // running markIdle here would demote the new task's .working back
            // to .idle.
            if !Task.isCancelled {
                self?.markIdle(id: id)
            }
        }
    }

    // Turn lifecycle is owned by the chat layer (only it knows when
    // client.prompt() starts and resolves). Notifications alone can't be the
    // signal: Hermes emits passive updates (available_commands_update,
    // usage_update, etc.) outside of an active turn, which would otherwise
    // pin the dot to green forever.
    func markTurnStarted(id: SessionId) {
        statuses[id] = .working
    }

    func markTurnFinished(id: SessionId) {
        if case .working = statuses[id] {
            statuses[id] = .idle
        }
    }

    private func observe(id: SessionId, notification: HermesNotification) {
        switch notification {
        case .permissionRequest:
            // Permission requests pause the turn waiting on the user; still
            // active in spirit, so keep showing working.
            statuses[id] = .working
        case let .clientRequestError(_, _, message):
            statuses[id] = .error(message)
        case let .sessionUpdate(notification):
            handleStateMutation(sessionId: id, update: notification.update)
        default:
            break
        }
    }

    private func handleStateMutation(sessionId: SessionId, update: SessionUpdate) {
        // Stale the cached SQLite snapshot when the agent has touched state on
        // the server. We don't refresh eagerly — the sidebar pulls on next
        // appearance or manual refresh.
        let mutates: Bool
        switch update {
        case let .toolCall(toolCall):
            mutates = recordAndDecide(
                sessionId: sessionId,
                toolCallId: toolCall.toolCallId,
                kind: toolCall.kind,
                status: toolCall.status
            )
        case let .toolCallUpdate(toolCall):
            mutates = recordAndDecide(
                sessionId: sessionId,
                toolCallId: toolCall.toolCallId,
                kind: toolCall.kind,
                status: toolCall.status
            )
        case .sessionInfoUpdate:
            mutates = true
        default:
            mutates = false
        }
        guard mutates, let snapshot else { return }
        Task { await snapshot.invalidate() }
    }

    /// Updates the per-session tool-kind cache, decides whether the event
    /// completes a mutating tool, and prunes the cache once the call resolves
    /// so the map stays bounded across long sessions.
    private func recordAndDecide(
        sessionId: SessionId,
        toolCallId: ToolCallId,
        kind: ToolKind?,
        status: ToolCallStatus?
    ) -> Bool {
        // ACP sets `kind` on the initial `tool_call` and usually omits it on
        // follow-up updates; remember it so completion events can look it up.
        if let kind {
            toolKinds[sessionId, default: [:]][toolCallId] = kind
        }
        let resolvedKind = kind ?? toolKinds[sessionId]?[toolCallId]
        let isCompleted = status == .completed
        let mutates = isCompleted && (resolvedKind.map(Self.mutatingToolKinds.contains) ?? false)

        // Prune once the call resolves — `.completed` and `.failed` are both
        // terminal in the ACP status enum, so the map stays bounded even for
        // sessions with thousands of tool calls.
        if isCompleted || status == .failed {
            toolKinds[sessionId]?[toolCallId] = nil
            if toolKinds[sessionId]?.isEmpty == true {
                toolKinds.removeValue(forKey: sessionId)
            }
        }
        return mutates
    }

    private static let mutatingToolKinds: Set<ToolKind> = [.edit, .delete, .move]

    private func markIdle(id: SessionId) {
        if case .working = statuses[id] {
            statuses[id] = .idle
        }
    }
}
