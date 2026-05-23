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

    let manager: SessionManager
    let adminRunner: HermesAdminRunning?
    let defaultCwd: String

    private var statusTasks: [SessionId: Task<Void, Never>] = [:]
    private var viewModels: [SessionId: LocalChatViewModel] = [:]
    private var pendingOpens: Set<SessionId> = []
    private let cwdStore: SessionsCwdStore

    init(
        manager: SessionManager,
        adminRunner: HermesAdminRunning? = nil,
        defaultCwd: String = FileManager.default.homeDirectoryForCurrentUser.path,
        cwdStore: SessionsCwdStore = SessionsCwdStore()
    ) {
        self.manager = manager
        self.adminRunner = adminRunner
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
        default:
            break
        }
    }

    private func markIdle(id: SessionId) {
        if case .working = statuses[id] {
            statuses[id] = .idle
        }
    }
}
