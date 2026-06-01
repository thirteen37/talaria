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
    var source: String?

    init(id: String, title: String, updatedAt: Date? = nil, cwd: String? = nil, source: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.source = source
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
        self.source = summary.source
    }
}

@MainActor
@Observable
final class SessionsStore {
    /// Distinguishes the two kinds of tab a window can hold. `.acp` is the
    /// native chat path (ACP over `Transport`/`Client`); `.tui` bypasses that
    /// stack entirely and renders the real `hermes chat --tui` inside an
    /// embedded terminal emulator (macOS only). Defaulting to `.acp` keeps
    /// every existing call site unchanged.
    enum SessionKind: Equatable {
        case acp
        case tui
    }

    /// Builds the `TUILaunchSpec` an embedded terminal needs to spawn a Hermes
    /// TUI. Injected per platform (nil on iOS / when unsupported), mirroring how
    /// `SessionManager`'s transport factory is supplied by the harness seam.
    /// `resume` is the real hermes session id when resuming, nil for a new chat.
    typealias TUISpecFactory = @MainActor @Sendable (_ resume: SessionId?, _ cwd: String) async throws -> TUILaunchSpec

    struct OpenSession: Identifiable, Equatable {
        var id: SessionId
        var cwd: String
        var title: String?
        /// `.acp` for native chat tabs, `.tui` for embedded-terminal tabs.
        var kind: SessionKind = .acp
        /// The real hermes session id this TUI tab resumes, or nil for a new
        /// chat. Only meaningful when `kind == .tui` (ACP tabs use the real id
        /// as their `id` directly).
        var resumeId: SessionId? = nil
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

    /// Builds the launch spec for a `.tui` tab, or nil where embedded terminals
    /// aren't supported (iOS, the mock harness). Wired by the macOS harness seam.
    let tuiSpecFactory: TUISpecFactory?
    /// Called when a `.tui` tab closes so the macOS terminal registry can
    /// terminate the live process. Nil where TUI tabs can't exist.
    private let onCloseTUI: (@MainActor @Sendable (SessionId) -> Void)?
    /// Launch specs for open `.tui` tabs, keyed by synthetic tab id. The detail
    /// view reads this to spawn (or re-attach) the embedded terminal; dropped
    /// when the tab closes.
    private(set) var tuiSpecs: [SessionId: TUILaunchSpec] = [:]
    /// Poll cadence for the TUI title reconciler. Initializer-injected (short in
    /// tests) so the dashboard-backed title refresh can be driven deterministically,
    /// mirroring the other injectables (`isAwaitingUserInput`, `tuiSpecFactory`).
    let tuiPollInterval: Duration

    private var statusTasks: [SessionId: Task<Void, Never>] = [:]
    /// One shared poller that refreshes the sidebar title of every *resumed*
    /// `.tui` tab from the dashboard. TUI tabs bypass ACP entirely, so they never
    /// receive a `session_info_update`; this is their only title source. Started
    /// when the first resumed TUI tab opens, torn down when the last one closes.
    private var tuiReconcileTask: Task<Void, Never>?
    private var viewModels: [SessionId: LocalChatViewModel] = [:]
    private var pendingOpens: Set<SessionId> = []
    /// Session ids whose TUI resume is in flight (the spec-build await window,
    /// which can be slow on a cold local profile while the login-shell PATH is
    /// probed). Mirrors `pendingOpens` so the one-mode-per-session guards catch
    /// a conflict in *both* directions before either tab is registered.
    private var pendingTUIOpens: Set<SessionId> = []
    private var toolKinds: [SessionId: [ToolCallId: ToolKind]] = [:]
    private let cwdStore: SessionsCwdStore
    /// Returns true while the open is blocked on interactive user input (the
    /// host-key trust prompt). The open timeout pauses while this is true so
    /// a slow fingerprint comparison doesn't trip the "handshake" deadline.
    private let isAwaitingUserInput: @MainActor @Sendable () -> Bool

    init(
        manager: SessionManager,
        adminRunner: HermesAdminRunning? = nil,
        dashboardClient: DashboardClient? = nil,
        defaultCwd: String = Platform.defaultHomeDirectory(),
        cwdStore: SessionsCwdStore = SessionsCwdStore(),
        isAwaitingUserInput: @escaping @MainActor @Sendable () -> Bool = { false },
        tuiSpecFactory: TUISpecFactory? = nil,
        onCloseTUI: (@MainActor @Sendable (SessionId) -> Void)? = nil,
        tuiPollInterval: Duration = .seconds(5)
    ) {
        self.manager = manager
        self.adminRunner = adminRunner
        self.dashboardClient = dashboardClient
        self.defaultCwd = defaultCwd
        self.cwdStore = cwdStore
        self.isAwaitingUserInput = isAwaitingUserInput
        self.tuiSpecFactory = tuiSpecFactory
        self.onCloseTUI = onCloseTUI
        self.tuiPollInterval = tuiPollInterval
    }

    /// True when this store can open `.tui` tabs (the macOS harness injected a
    /// spec factory). Drives whether the sidebar surfaces the TUI affordances.
    var supportsTUI: Bool { tuiSpecFactory != nil }

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
        // One mode per session id: if this session is already open (or being
        // opened) as a TUI tab, focus it rather than spawning a second hermes
        // that resumes the same session concurrently. The synthetic `tui:<id>`
        // id means the same-id check below would otherwise miss it; the
        // pending-set check closes the window before the tab is registered.
        let tuiId = tuiTabId(for: summary.id)
        if openSessions.contains(where: { $0.id == tuiId }) || pendingTUIOpens.contains(summary.id) {
            selection = tuiId
            return
        }
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

        do {
            let source = try await effectiveSource(for: summary)
            if let source, source != "acp" {
                try await openReadOnly(summary, source: source)
                return
            }

            let workingDir = cwdStore.cwd(for: summary.id) ?? summary.cwd ?? defaultCwd
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

    private func effectiveSource(for summary: HermesSessionSummary) async throws -> String? {
        if let source = summary.source {
            return source
        }
        guard let dashboardClient else {
            return nil
        }
        let detail = try await dashboardClient.sessionDetail(id: summary.id)
        return detail.source
    }

    private func openReadOnly(_ summary: HermesSessionSummary, source: String) async throws {
        guard let dashboardClient else {
            lastError = "Dashboard not reachable"
            return
        }
        let payload = try await dashboardClient.sessionMessages(id: summary.id)
        let messages = SessionHistoryMapper.messages(from: payload.messages)
        let workingDir = summary.cwd ?? defaultCwd
        let viewModel = LocalChatViewModel(
            sessionId: summary.id,
            cwd: workingDir,
            messages: messages,
            source: source
        )
        // Seed the header for read-only sessions: they never receive a live
        // `session_info_update`, so this dashboard title is their only chance to
        // show a name instead of "Chat". Treat empty as nil so the fallback wins.
        viewModel.title = summary.title.isEmpty ? nil : summary.title
        viewModels[summary.id] = viewModel
        statuses[summary.id] = .idle
        insert(OpenSession(id: summary.id, cwd: workingDir, title: summary.title))
        selection = summary.id
    }

    /// Opens a Hermes TUI tab — a new chat (`resume: nil`) or a resume of an
    /// existing session — rendered by an embedded terminal instead of the ACP
    /// `ChatView`. No-op with a surfaced error where TUI isn't supported.
    ///
    /// The tab id is synthetic (`tui:<sessionId-or-uuid>`) so a TUI tab never
    /// collides with an ACP tab of the same session. Resuming a session that
    /// already has a TUI tab just focuses it.
    func openTUI(resume summary: HermesSessionSummary? = nil, cwd: String? = nil) async {
        guard let tuiSpecFactory else {
            lastError = "Terminal sessions aren't supported on this platform."
            return
        }
        let resumeId = summary?.id
        // One mode per session id: never run a TUI alongside an inline ACP tab
        // for the same session (two hermes processes resuming one session). The
        // browser disables this action when inline, but guard here too so a
        // stale UI state can't slip a second process through. `pendingOpens`
        // covers an inline open that's still mid-connect — its `.acp` tab isn't
        // in `openSessions` yet, so `isOpenInline` alone would miss it and let
        // both resume the same session at once.
        if let resumeId, isOpenInline(resumeId) || pendingOpens.contains(resumeId) {
            selection = resumeId
            return
        }
        let tabId = resumeId.map { tuiTabId(for: $0) } ?? ("tui:" + UUID().uuidString)
        if openSessions.contains(where: { $0.id == tabId }) {
            selection = tabId
            return
        }
        let workingDir = cwd
            ?? resumeId.flatMap { cwdStore.cwd(for: $0) }
            ?? summary?.cwd
            ?? defaultCwd
        AppLog.session.info("openTUI: begin resume=\(resumeId ?? "nil", privacy: .public) cwd=\(workingDir, privacy: .public)")
        // Mark the resume in flight across the spec-build await so a concurrent
        // inline open of the same session sees the conflict before our tab is
        // registered (symmetric with `pendingOpens` on the ACP side).
        if let resumeId { pendingTUIOpens.insert(resumeId) }
        defer { if let resumeId { pendingTUIOpens.remove(resumeId) } }
        do {
            let spec = try await tuiSpecFactory(resumeId, workingDir)
            tuiSpecs[tabId] = spec
            insert(OpenSession(
                id: tabId,
                cwd: workingDir,
                title: summary?.title,
                kind: .tui,
                resumeId: resumeId
            ))
            selection = tabId
            // A resumed tab carries the real hermes id, so its persisted title
            // can be looked up from the dashboard; start the poller that keeps the
            // sidebar row in sync. A brand-new TUI chat has no id Talaria knows,
            // so it stays on the "Terminal"/short-id fallback (out of scope).
            if resumeId != nil {
                ensureTUIReconciler()
            }
        } catch {
            AppLog.session.error("openTUI: failed: \(String(describing: error), privacy: .public)")
            lastError = Self.describe(error)
        }
    }

    /// True when an `.acp` (inline chat) tab is open for `id`. The Sessions
    /// browser uses this to disable "Open as TUI" — one mode per session id at
    /// a time (the conflict rule).
    func isOpenInline(_ id: SessionId) -> Bool {
        openSessions.contains { $0.id == id && $0.kind == .acp }
    }

    /// The synthetic tab id a TUI tab uses to resume `sessionId`. Centralized so
    /// the open paths and the one-mode-per-session guards agree on its shape.
    private func tuiTabId(for sessionId: SessionId) -> SessionId {
        "tui:" + sessionId
    }

    /// The launch spec for an open `.tui` tab, if any. Read by the detail view.
    func tuiSpec(for id: SessionId) -> TUILaunchSpec? {
        tuiSpecs[id]
    }

    func viewModel(for id: SessionId) -> LocalChatViewModel? {
        viewModels[id]
    }

    private func ensureViewModel(id: SessionId, cwd: String) async {
        if viewModels[id] != nil {
            return
        }
        let vm = LocalChatViewModel(manager: manager, sessionId: id, cwd: cwd, store: self)
        // Seed the header from any title the open session already carries (e.g.
        // a dashboard title captured by `openExisting`), so reopening a titled
        // session shows it immediately, before any new notification arrives.
        // `OpenSession.title` is "" (not nil) for an untitled session, so map
        // empty to nil — otherwise `navigationTitle` renders blank, not "Chat".
        vm.title = openSessions.first(where: { $0.id == id })?.title.flatMap { $0.isEmpty ? nil : $0 }
        viewModels[id] = vm
        await vm.start()
    }

    func closeTab(_ id: SessionId) async {
        statusTasks[id]?.cancel()
        statusTasks[id] = nil
        statuses[id] = nil
        toolKinds.removeValue(forKey: id)
        let isTUI = openSessions.first(where: { $0.id == id })?.kind == .tui
        openSessions.removeAll { $0.id == id }
        if selection == id {
            selection = openSessions.first?.id
        }
        // Once the last resumed TUI tab is gone there's nothing left to refresh,
        // so stop polling the dashboard.
        if !openSessions.contains(where: { $0.kind == .tui && $0.resumeId != nil }) {
            tuiReconcileTask?.cancel()
            tuiReconcileTask = nil
        }
        // TUI tabs never touched the ACP stack (`manager` / `viewModels`); they
        // own a live terminal process instead. Drop the spec and let the macOS
        // registry terminate the process.
        if isTUI {
            tuiSpecs.removeValue(forKey: id)
            onCloseTUI?(id)
            return
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
            // Mirror into the cached view model too, so an open chat's header
            // reflects the rename immediately instead of waiting on a live
            // `session_info_update` (which may never come for this session).
            viewModels[id]?.title = title
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
        // Routes always-on session updates: it keeps the per-session `toolKinds`
        // cache pruned, and captures Hermes' auto-generated session title (the
        // agent → client `session_info_update`) into `OpenSession.title` — the
        // sidebar's source of truth — plus the cached view model so the chat
        // header updates live, whether or not the chat view is currently visible.
        switch update {
        case let .sessionInfoUpdate(info):
            if let index = openSessions.firstIndex(where: { $0.id == sessionId }) {
                applyTitle(info.title, to: index)
            }
            // Mirror into the cached view model so the chat header updates live —
            // same never-blank guard as `applyTitle`.
            if let title = normalizedTitle(info.title) {
                viewModels[sessionId]?.title = title
            }
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

    /// Trims a raw title and collapses an empty/whitespace one to nil, so callers
    /// share the single "a blank title is no title" rule.
    private func normalizedTitle(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Writes a resolved session title onto the open tab at `index`, enforcing the
    /// shared "never blank an existing title" rule. Used by both the ACP
    /// `session_info_update` path and the TUI dashboard reconciler.
    private func applyTitle(_ rawTitle: String?, to index: Int) {
        guard let title = normalizedTitle(rawTitle) else {
            return
        }
        openSessions[index].title = title
    }

    /// Starts the dashboard-backed title poller for resumed `.tui` tabs if it
    /// isn't already running. No-ops without a dashboard (the only title source)
    /// or when a poller is already live — `openTUI` calls it for every resumed tab,
    /// but one shared loop covers them all.
    private func ensureTUIReconciler() {
        guard dashboardClient != nil, tuiReconcileTask == nil else {
            return
        }
        tuiReconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                // Self-exit when the last resumed TUI tab is gone (a belt-and-braces
                // mirror of the teardown in `closeTab`).
                guard self.openSessions.contains(where: { $0.kind == .tui && $0.resumeId != nil }) else {
                    self.tuiReconcileTask = nil
                    return
                }
                await self.reconcileTUITitles()
                // Transient dashboard errors are swallowed in `reconcileTUITitles`;
                // the sleep is the back-off. Never surfaced as `lastError`.
                try? await Task.sleep(for: self.tuiPollInterval)
            }
        }
    }

    /// One dashboard sweep: pull the session list and copy each resumed TUI tab's
    /// persisted title into its sidebar row. Swallows transient errors (the poll
    /// loop retries) so a momentarily-unreachable dashboard never surfaces a toast.
    private func reconcileTUITitles() async {
        guard let dashboardClient,
              let response = try? await dashboardClient.listSessions(limit: 200) else {
            return
        }
        // Re-resolve indices after the await — tabs may have opened/closed while
        // the request was in flight.
        for summary in response.sessions {
            guard let index = openSessions.firstIndex(
                where: { $0.kind == .tui && $0.resumeId == summary.id }
            ) else {
                continue
            }
            applyTitle(summary.title, to: index)
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
