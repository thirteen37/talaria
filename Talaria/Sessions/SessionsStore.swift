import Foundation
import HermesKit
import SwiftUI

/// UI-shaped summary of a Hermes session for sidebar rows. Lived in
/// `HermesDB.swift` while the SQLite snapshot path was active; now that the
/// dashboard `GET /api/sessions` is the only source, we keep the shape here
/// (close to its sole consumer) and adapt `DashboardSessionSummary` into it
/// at the boundary.
struct HermesSessionSummary: Identifiable, Equatable {
    var id: String
    var title: String
    var updatedAt: Date?
    var cwd: String?

    init(id: String, title: String, updatedAt: Date? = nil, cwd: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.cwd = cwd
    }

    init(_ summary: DashboardSessionSummary) {
        self.id = summary.id
        self.title = summary.title ?? ""
        // Dashboard exposes startedAt (creation), not updatedAt; map it across
        // for the sidebar's relative-time render. Losing the "modified since"
        // semantics is acceptable — the next browser refresh re-fetches and
        // ordering on the server is recency-first by default.
        self.updatedAt = summary.startedAt.map { Date(timeIntervalSince1970: $0) }
        self.cwd = nil
    }
}

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

    let manager: SessionManager
    /// CLI admin runner — used only for `hermes sessions rename` since the
    /// dashboard doesn't expose a rename route. Delete goes through the
    /// dashboard via `dashboardClient`.
    let adminRunner: HermesAdminRunning?
    /// Dashboard client for sessions delete and (eventually) any sessions
    /// metadata writes that get a route upstream. Optional because the
    /// dashboard may not be reachable yet when the store is constructed —
    /// the view layer is responsible for surfacing that as a "connecting…"
    /// state, not for blocking session-tab management.
    var dashboardClient: DashboardClient?
    let defaultCwd: String

    private var statusTasks: [SessionId: Task<Void, Never>] = [:]
    private var viewModels: [SessionId: LocalChatViewModel] = [:]
    private var pendingOpens: Set<SessionId> = []
    private var toolKinds: [SessionId: [ToolCallId: ToolKind]] = [:]
    private let cwdStore: SessionsCwdStore

    init(
        manager: SessionManager,
        adminRunner: HermesAdminRunning? = nil,
        dashboardClient: DashboardClient? = nil,
        defaultCwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        cwdStore: SessionsCwdStore = SessionsCwdStore()
    ) {
        self.manager = manager
        self.adminRunner = adminRunner
        self.dashboardClient = dashboardClient
        self.defaultCwd = defaultCwd
        self.cwdStore = cwdStore
    }

    func openNew(cwd: String? = nil) async {
        let workingDir = cwd ?? defaultCwd
        do {
            let state = try await manager.openNew(cwd: workingDir)
            cwdStore.record(id: state.id, cwd: state.cwd)
            insert(OpenSession(id: state.id, cwd: state.cwd, title: nil))
            selection = state.id
            attachStatus(id: state.id)
            await ensureViewModel(id: state.id, cwd: state.cwd)
        } catch {
            lastError = error.localizedDescription
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
        defer { pendingOpens.remove(summary.id) }

        let workingDir = cwdStore.cwd(for: summary.id) ?? summary.cwd ?? defaultCwd
        do {
            let state = try await manager.openExisting(id: summary.id, cwd: workingDir)
            cwdStore.record(id: state.id, cwd: state.cwd)
            insert(OpenSession(id: state.id, cwd: state.cwd, title: summary.title))
            selection = state.id
            attachStatus(id: state.id)
            await ensureViewModel(id: state.id, cwd: state.cwd)
        } catch SessionManagerError.duplicateSession {
            // A concurrent caller registered first; just focus the session.
            selection = summary.id
        } catch {
            lastError = error.localizedDescription
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteSession(_ id: SessionId) async {
        guard let dashboardClient else {
            lastError = "Dashboard not reachable"
            return
        }
        // Tear down our ACP session first so the running `hermes acp` process
        // releases its writer on the row before the dashboard delete fires.
        // Running both in parallel can produce FK errors or orphan messages.
        await closeTab(id)
        do {
            try await dashboardClient.deleteSession(id: id)
            cwdStore.forget(id: id)
            browserRefreshToken &+= 1
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
        // Side effects of state mutations used to drive snapshot invalidation;
        // with the dashboard-backed Sessions browser the sidebar re-queries
        // on its own refresh token, and mutation tracking now exists only to
        // keep the per-session `toolKinds` cache pruned.
        switch update {
        case let .toolCall(toolCall):
            _ = recordAndDecide(
                sessionId: sessionId,
                toolCallId: toolCall.toolCallId,
                kind: toolCall.kind,
                status: toolCall.status
            )
        case let .toolCallUpdate(toolCall):
            _ = recordAndDecide(
                sessionId: sessionId,
                toolCallId: toolCall.toolCallId,
                kind: toolCall.kind,
                status: toolCall.status
            )
        default:
            break
        }
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
