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
    /// Real last-activity time from the dashboard (vs `updatedAt`, which is
    /// seeded from creation time). The browser prefers this when present.
    var lastActive: Date?
    var isActive: Bool
    /// Conversation excerpt for the row. Nil/empty for the lean search path.
    var preview: String?
    var model: String?
    var messageCount: Int?
    var toolCallCount: Int?
    /// Input + output tokens for the session, or nil when neither is reported.
    var tokenTotal: Int?
    /// Pre-formatted cost chip text (e.g. `$0.12`, `~$0.34`), or nil when the
    /// server reports no meaningful cost. Computed once at the boundary.
    var costDisplay: String?
    /// Numeric session cost in USD (actual when reported, else a meaningful
    /// estimate), or nil when no meaningful cost is available — the same value
    /// `costDisplay` renders. Used by the Filter menu's cost floor. Nil on the
    /// lean search path.
    var costUsd: Double?

    init(
        id: String,
        title: String,
        updatedAt: Date? = nil,
        cwd: String? = nil,
        source: String? = nil,
        lastActive: Date? = nil,
        isActive: Bool = false,
        preview: String? = nil,
        model: String? = nil,
        messageCount: Int? = nil,
        toolCallCount: Int? = nil,
        tokenTotal: Int? = nil,
        costDisplay: String? = nil,
        costUsd: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.source = source
        self.lastActive = lastActive
        self.isActive = isActive
        self.preview = preview
        self.model = model
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.tokenTotal = tokenTotal
        self.costDisplay = costDisplay
        self.costUsd = costUsd
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
        self.lastActive = summary.lastActive.map { Date(timeIntervalSince1970: $0) }
        self.isActive = summary.isActive ?? false
        // Treat a blank preview as none so the row doesn't render an empty line.
        let trimmedPreview = summary.preview?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preview = (trimmedPreview?.isEmpty == false) ? trimmedPreview : nil
        self.model = summary.model
        self.messageCount = summary.messageCount
        self.toolCallCount = summary.toolCallCount
        let tokenParts = [summary.inputTokens, summary.outputTokens].compactMap { $0 }
        self.tokenTotal = tokenParts.isEmpty ? nil : tokenParts.reduce(0, +)
        let resolvedCost = Self.resolvedCost(
            estimated: summary.estimatedCostUsd,
            actual: summary.actualCostUsd,
            status: summary.costStatus
        )
        self.costUsd = resolvedCost?.value
        self.costDisplay = resolvedCost.map {
            $0.isEstimate ? String(format: "~$%.2f", $0.value) : String(format: "$%.2f", $0.value)
        }
    }

    /// The time the row should display: real last activity when the server
    /// reports it, else the creation-derived `updatedAt`.
    var displayTime: Date? { lastActive ?? updatedAt }

    /// Resolves the single cost number both `costUsd` and `costDisplay` use, or
    /// nil when no meaningful cost is available. Many setups report
    /// `cost_status: "unknown"` with `0.0`, which stays hidden. A real
    /// `actual_cost_usd` is used verbatim; an estimate is flagged so the chip can
    /// prefix it with `~`. Factoring this keeps the string and the number
    /// consistent.
    private static func resolvedCost(
        estimated: Double?,
        actual: Double?,
        status: String?
    ) -> (value: Double, isEstimate: Bool)? {
        if let actual, actual > 0 {
            return (actual, false)
        }
        if let estimated, estimated > 0, status?.lowercased() != "unknown" {
            return (estimated, true)
        }
        return nil
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
        /// The turn is paused waiting on the user (permission / question /
        /// secret prompt). Distinct from `.working` so "needs you" reads
        /// differently from "busy" in the sidebar and the window badge.
        case awaitingInput
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

    /// Wired by the window harness to its connection-recovery entry point
    /// (``ServerWindowHarness/recoverConnectionIfNeeded()``). Invoked when a live
    /// chat's notification stream dies unexpectedly — the macOS silent-WS-death
    /// trigger. Every harness wires this (the designated init, incl. `makeMock()`);
    /// nil only for unit-test stores constructed directly without a harness.
    var requestRecovery: (@MainActor () -> Void)?

    /// Reports whether the harness already has a recovery pass in flight. The
    /// recovery driver consults it so it doesn't count a still-running pass (a
    /// `performRecovery()` can block on a ~15s SSH connect timeout) as a failed
    /// attempt and give up early. Wired alongside ``requestRecovery``; nil only for
    /// unit-test stores built without a harness, where it reads as "not recovering".
    var recoveryInFlight: (@MainActor () -> Bool)?

    /// Coalesces silent-stream-death recovery into a single driver that keeps
    /// re-asking the harness to recover until no live session's stream is dead.
    /// Non-nil while draining; further deaths fold into it. See
    /// ``handleLiveSessionDied(id:)``.
    private var recoveryDriver: Task<Void, Never>?

    /// Gap between recovery re-attempts while sessions remain dead — rate-limits a
    /// flapping connection so it can't spin a tight re-resume loop. Injectable so
    /// the retry cadence can be driven deterministically in tests.
    private let recoveryDebounce: TimeInterval

    /// How many *completed* recovery passes may fail to shrink the dead set before
    /// the driver gives up. Past this, a persistently-unreachable dashboard stops
    /// the loop and degrades to the manual-Reconnect error banner instead of an
    /// unbounded full-reconnect loop. Progress (the set shrinking) resets the count.
    private static let maxStalledRecoveryAttempts = 5

    /// This window's profile id, stamped onto every notification so a tapped
    /// banner can be routed back to the right window. Nil for the mock harness /
    /// tests, which never notify.
    let profileId: UUID?
    /// App-wide notification bridge. Nil where notifications aren't wired (mock
    /// harness, unit tests) — every notify call is a no-op then.
    let notifier: ChatNotifier?
    /// Whether this window is the one the user is actively looking at (its window
    /// is frontmost). Reported by the window root's `trackWindowForeground`
    /// modifier. Combined with `selection` to suppress notifications for a chat
    /// the user is already watching. Defaults to `true` so a notification never
    /// fires for a freshly-built store before the first foreground report lands.
    var isWindowForeground = true

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
        tuiPollInterval: Duration = .seconds(5),
        recoveryDebounce: TimeInterval = 5,
        profileId: UUID? = nil,
        notifier: ChatNotifier? = nil
    ) {
        self.manager = manager
        self.adminRunner = adminRunner
        self.dashboardClient = dashboardClient
        self.defaultCwd = defaultCwd
        self.recoveryDebounce = recoveryDebounce
        self.cwdStore = cwdStore
        self.isAwaitingUserInput = isAwaitingUserInput
        self.tuiSpecFactory = tuiSpecFactory
        self.onCloseTUI = onCloseTUI
        self.tuiPollInterval = tuiPollInterval
        self.profileId = profileId
        self.notifier = notifier
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
                throw GatewayChatError.server(
                    "Connected, but the server didn't complete the Hermes handshake within \(Int(seconds))s. "
                    + "Check that the dashboard is reachable for this profile."
                )
            }
            defer { group.cancelAll() }
            // First task to finish wins; cancel the rest.
            return try await group.next()!
        }
    }

    /// `select` controls whether a successful open also focuses the tab. The
    /// default (`true`) is what every interactive caller wants. Cold-relaunch
    /// restore passes `false` so it can re-open several tabs *without* churning the
    /// visible selection — it sets the recorded selection once at the end. Keeping
    /// the selection still during a restore also lets the window treat any selection
    /// change as an unambiguous live user tap (cancelling the restore).
    func openExisting(_ summary: HermesSessionSummary, select: Bool = true) async {
        // One mode per session id: if this session is already open (or being
        // opened) as a TUI tab, focus it rather than spawning a second hermes
        // that resumes the same session concurrently. The synthetic `tui:<id>`
        // id means the same-id check below would otherwise miss it; the
        // pending-set check closes the window before the tab is registered.
        let tuiId = tuiTabId(for: summary.id)
        if openSessions.contains(where: { $0.id == tuiId }) || pendingTUIOpens.contains(summary.id) {
            if select { selection = tuiId }
            return
        }
        // Either already open or being opened concurrently — treat a second
        // tap as a benign "switch to it once it exists" intent instead of
        // racing through manager.openExisting and surfacing duplicateSession
        // as an error toast.
        if openSessions.contains(where: { $0.id == summary.id }) || pendingOpens.contains(summary.id) {
            if select { selection = summary.id }
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
            // Talaria's own live chat is now created over the `/api/ws` gateway,
            // which Hermes tags `source="tui"` (its embedded-chat surface) — not
            // the legacy `"acp"` the old subprocess backend used. Both are
            // resumable as live, editable chats via `session.resume`, so both
            // must stay editable; only genuinely non-live sources (e.g. a
            // one-shot `"cli"` run) open read-only.
            if let source, !Self.liveResumableSources.contains(source.lowercased()) {
                try await openReadOnly(summary, source: source, select: select)
                return
            }

            let workingDir = cwdStore.cwd(for: summary.id) ?? summary.cwd ?? defaultCwd
            let state = try await Self.withTimeout(Self.openTimeout, isPaused: isAwaitingUserInput) {
                try await self.manager.openExisting(id: summary.id, cwd: workingDir)
            }
            cwdStore.record(id: state.id, cwd: state.cwd)
            insert(OpenSession(id: state.id, cwd: state.cwd, title: summary.title))
            if select { selection = state.id }
            attachStatus(id: state.id)
            // Seed the prior transcript so a resumed session shows its history
            // immediately (the live gateway doesn't replay it as updates).
            let history = await liveHistory(for: state.id)
            await ensureViewModel(id: state.id, cwd: state.cwd, seedMessages: history)
        } catch SessionManagerError.duplicateSession {
            // A concurrent caller registered first; just focus the session.
            if select { selection = summary.id }
        } catch {
            AppLog.session.error("openExisting: failed: \(String(describing: error), privacy: .public)")
            lastError = Self.describe(error)
        }
    }

    /// Session `source` values Talaria can reopen as a live, editable chat over
    /// the dashboard gateway. `"acp"` = the legacy ACP subprocess backend;
    /// `"tui"` = the `/api/ws` gateway surface (Talaria's current backend and the
    /// dashboard's own chat tab). Anything else opens read-only.
    private static let liveResumableSources: Set<String> = ["acp", "tui"]

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

    /// Loads a resumed session's prior transcript via the dashboard
    /// (`GET /api/sessions/{id}` messages) so the live chat opens populated.
    /// Best-effort: a failure here just yields an empty seed (the session still
    /// opens live), rather than aborting the open.
    private func liveHistory(for id: SessionId) async -> [ChatTranscriptMessage] {
        guard let dashboardClient else { return [] }
        do {
            let payload = try await dashboardClient.sessionMessages(id: id)
            return SessionHistoryMapper.messages(from: payload.messages)
        } catch {
            AppLog.session.error("history seed failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Re-seeds an open session's transcript from the dashboard's authoritative
    /// message list (the same `GET /api/sessions/{id}` used to seed a resumed
    /// chat). Used after a harness-side rewind (`/undo` → prefill) so the local
    /// transcript matches the server instead of still showing the undone turn.
    ///
    /// Best-effort: an empty/failed fetch leaves the current transcript untouched
    /// rather than blanking a populated chat. Resolves by the session's stored
    /// dashboard id, so it resyncs resumed sessions; a brand-new session still
    /// keyed by its gateway runtime id won't match a dashboard row and is left
    /// as-is (no regression — that was the prior behavior for every command).
    func refreshTranscript(_ id: SessionId) async {
        guard let vm = viewModels[id] else { return }
        let history = await liveHistory(for: id)
        guard !history.isEmpty else { return }
        vm.replaceTranscript(with: history)
    }

    /// Re-establishes open live chat tabs after the dashboard tunnel was rebuilt
    /// (the iOS background→foreground reconnect, or a manual Reconnect). The old
    /// `/api/ws` WebSocket died with the previous tunnel, so each `.acp` tab's
    /// manager session is dead — its notification stream finished and the
    /// underlying client is gone. For every editable live tab this tears the dead
    /// session down, re-resumes over the fresh tunnel, re-seeds history, and
    /// re-subscribes the view model. Read-only `.acp` tabs (no manager) and
    /// `.tui` tabs are skipped; a tab the dashboard no longer has (an unpersisted
    /// new chat) is marked lost rather than re-resumed. No-op without a dashboard.
    ///
    /// Pass `limitedTo` to scope the re-resume to a specific set of ids — used by
    /// the WS-death-after-a-passing-probe path, where only some chats' sockets died
    /// (each chat owns its own `GatewayWebSocket`, so one channel reset can leave
    /// the others healthy and mid-stream). `nil` re-resumes every live tab, the
    /// full-reconnect case where the whole tunnel was torn down.
    func recoverLiveSessions(limitedTo ids: Set<SessionId>? = nil) async {
        guard dashboardClient != nil else { return }
        // Snapshot up front: the loop awaits, and close/openExisting mutate
        // `openSessions` underneath us.
        let liveTabs = openSessions.filter { tab in
            tab.kind == .acp && (ids.map { $0.contains(tab.id) } ?? true)
        }
        for tab in liveTabs {
            let id = tab.id
            guard let vm = viewModels[id], !vm.isReadOnly else { continue }

            // 1. Tear down the dead manager session (the step the manual
            //    reconnect used to skip, leaving the tab permanently dead).
            //    Cancel the VM's notification loop *before* closing so the
            //    stream-end reads as intentional (cancelled) — a still-live session
            //    being recovered here must not trip `handleLiveSessionDied`.
            statusTasks[id]?.cancel()
            statusTasks[id] = nil
            vm.suspendNotifications()
            await manager.close(id: id)

            // 2. Only sessions the gateway persisted are resumable. `openExisting`
            //    tabs always are (their id is the stored id); a brand-new chat is
            //    resumable iff the gateway already wrote it.
            guard await dashboardHasSession(id) else {
                vm.markConnectionLost()
                continue
            }

            // 3. Re-resume live over the fresh tunnel.
            do {
                _ = try await Self.withTimeout(Self.openTimeout, isPaused: isAwaitingUserInput) {
                    try await self.manager.openExisting(id: id, cwd: tab.cwd)
                }
            } catch {
                AppLog.session.error("recoverLiveSessions: re-resume failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                vm.markConnectionLost()
                continue
            }

            // 4. Re-seed the transcript from the dashboard's authoritative list.
            //    Replace, never blank: a failed/empty fetch leaves history visible.
            let history = await liveHistory(for: id)
            if !history.isEmpty {
                vm.replaceTranscript(with: history)
            }

            // 5. Re-attach the store's status task and re-subscribe the VM.
            attachStatus(id: id)
            await vm.restart()
        }
    }

    /// Ids of open, editable live chat tabs whose notification stream died — the
    /// live-chat `/api/ws` socket died (gateway restart, channel reset) while the
    /// dashboard HTTP channel stayed healthy, so a passing `/api/status` probe alone
    /// would miss it. Each live chat owns its own socket, so this can be a strict
    /// subset of the open tabs; the iOS background→foreground recovery re-resumes
    /// exactly this set over the still-good tunnel, leaving healthy chats untouched.
    /// Only `.acp` tabs have a manager session; read-only tabs (no live stream) and
    /// `.tui` tabs are never included.
    func deadLiveSessionIds() async -> Set<SessionId> {
        let dead = Set(await manager.deadSessionIds())
        guard !dead.isEmpty else { return [] }
        return Set(openSessions.compactMap { tab -> SessionId? in
            guard tab.kind == .acp,
                  dead.contains(tab.id),
                  viewModels[tab.id]?.isReadOnly == false else { return nil }
            return tab.id
        })
    }

    /// A live chat's notification stream died while the session was meant to be
    /// alive — the macOS silent-WS-death case (a keepalive ping finally failed, or
    /// the receive timeout fired). On iOS the background→foreground hook recovers
    /// this; macOS has no such hook, so the chat VM routes the stream end here.
    /// Asks the harness to recover (probe `/api/status`, then re-resume only the
    /// dead sessions via ``recoverLiveSessions(limitedTo:)``).
    ///
    /// Coalesced into a single **driver** keyed off the dead-session set, not a
    /// wall-clock debounce: it triggers a recovery immediately, then keeps
    /// re-triggering for as long as any live session's stream is still dead
    /// (``deadLiveSessionIds()``). Keying off the set (rather than a one-shot timer)
    /// guarantees a session whose socket died *after* an in-flight recovery
    /// snapshotted its set — or one whose recovery outlasts any fixed window — still
    /// gets a pass, instead of stranding until a manual Reconnect.
    ///
    /// **Bounded.** Each loop waits a ``recoveryDebounce`` (rate-limiting a flapping
    /// connection) and skips while a pass is still in flight (so a slow
    /// `performRecovery` isn't miscounted). A *completed* pass that fails to shrink
    /// the dead set counts as stalled; after ``maxStalledRecoveryAttempts`` stalls
    /// the driver gives up — a fully-unreachable dashboard then degrades to the
    /// existing manual-Reconnect error banner rather than an unbounded reconnect
    /// loop. Forward progress (the set shrinking) resets the count, and an empty set
    /// (every session re-resumed or marked lost) ends the driver cleanly.
    func handleLiveSessionDied(id: SessionId) {
        // No harness wired (mock/tests) → nothing to drive. A driver already
        // running re-scans the whole dead set each pass, so this death is covered.
        guard requestRecovery != nil, recoveryDriver == nil else { return }
        requestRecovery?()   // immediate first attempt
        recoveryDriver = Task { [weak self] in
            guard let self else { return }
            defer { self.recoveryDriver = nil }
            var stalled = 0
            var previousDeadCount = Int.max
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.recoveryDebounce * 1_000_000_000))
                // Don't evaluate (or re-trigger) while the harness is mid-pass —
                // a `performRecovery` can block on a slow SSH connect, and counting
                // those waits as failures would give up before it even finished.
                if self.recoveryInFlight?() ?? false { continue }
                let deadCount = await self.deadLiveSessionIds().count
                if deadCount == 0 { break }   // every dead session resolved → done
                // A completed pass that didn't shrink the set is a stall; progress
                // resets the counter. Give up once a persistently-down dashboard
                // has stalled enough — the manual-Reconnect banner takes over.
                stalled = deadCount < previousDeadCount ? 0 : stalled + 1
                previousDeadCount = deadCount
                if stalled >= Self.maxStalledRecoveryAttempts { break }
                self.requestRecovery?()
            }
        }
    }

    /// Whether the dashboard still has a row for `id` — i.e. the session
    /// persisted server-side and can be re-resumed after a reconnect. A thrown
    /// error (404 for an unpersisted new chat, or any transient failure) counts
    /// as "no", so the caller marks the tab lost rather than re-resuming a
    /// session that isn't there.
    private func dashboardHasSession(_ id: SessionId) async -> Bool {
        guard let dashboardClient else { return false }
        do {
            _ = try await dashboardClient.sessionDetail(id: id)
            return true
        } catch {
            return false
        }
    }

    /// Re-opens a saved session for cold-relaunch restore. Pre-checks that the
    /// dashboard still has the session and **skips silently** otherwise, so a
    /// server-deleted or never-persisted saved id degrades without the red error
    /// banner a failed `openExisting` would raise via `lastError` — matching
    /// ``recoverLiveSessions()``'s `dashboardHasSession` guard. Opens **without
    /// selecting** (the window applies the recorded selection once at the end).
    /// `title` is the persisted label so the re-opened tab shows its name straight
    /// away (the dashboard detail carries no title). Returns whether the tab is
    /// open afterward.
    func reopenForRestore(id: SessionId, title: String = "") async -> Bool {
        guard await dashboardHasSession(id) else { return false }
        await openExisting(HermesSessionSummary(id: id, title: title), select: false)
        return openSessions.contains { $0.id == id }
    }

    private func openReadOnly(_ summary: HermesSessionSummary, source: String, select: Bool = true) async throws {
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
        if select { selection = summary.id }
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

    private func ensureViewModel(
        id: SessionId,
        cwd: String,
        seedMessages: [ChatTranscriptMessage] = []
    ) async {
        if viewModels[id] != nil {
            return
        }
        let vm = LocalChatViewModel(manager: manager, sessionId: id, cwd: cwd, store: self)
        // Seed the prior transcript for a resumed session. The live gateway
        // backend carries history in the `session.resume` *result* (not as
        // streamed updates the way the old ACP path did), so without this the
        // chat would open blank until the next turn. New live turns stream in
        // and append after the seed.
        if !seedMessages.isEmpty {
            vm.messages = seedMessages
        }
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
        // TUI tabs never touched the chat stack (`manager` / `viewModels`); they
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

    /// Whether session rename is available. Rename has no dashboard route, so it
    /// falls back to `hermes sessions rename` via the CLI admin runner — which is
    /// absent on iOS. The chat toolbar and browser rows gate their Rename button
    /// on this; Delete/Export work everywhere (both go through the dashboard).
    var supportsRename: Bool { adminRunner != nil }

    /// Fetches a session's transcript from the dashboard and serializes it to
    /// JSONL for export. Returns nil (and sets `lastError`) when the dashboard is
    /// unreachable, the fetch fails, or the session has no messages — so the
    /// caller can skip presenting a file exporter for an empty/failed export.
    func transcriptJSONL(for id: SessionId) async -> String? {
        guard let dashboardClient else {
            lastError = "Dashboard not reachable"
            return nil
        }
        do {
            let payload = try await dashboardClient.sessionMessages(id: id)
            let jsonl = SessionTranscriptExporter.jsonl(from: payload.messages)
            guard !jsonl.isEmpty else {
                lastError = "This session has no messages to export."
                return nil
            }
            return jsonl
        } catch {
            lastError = error.localizedDescription
            return nil
        }
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

    /// Updates the in-memory title for an open session (and its cached view
    /// model) without the CLI. Used by the `/title` slash shim, which renames via
    /// the gateway `session.title` RPC; mirrors the `session_info_update` path
    /// (`handleStateMutation`). The CLI-based `renameSession` (sessions-list UI)
    /// is left as-is.
    func updateTitle(_ id: SessionId, to title: String) {
        if let index = openSessions.firstIndex(where: { $0.id == id }) {
            applyTitle(title, to: index)
        }
        if let normalized = normalizedTitle(title) {
            viewModels[id]?.title = normalized
        }
        browserRefreshToken &+= 1
    }

    func deleteSession(_ id: SessionId) async {
        guard let dashboardClient else {
            lastError = "Dashboard not reachable"
            return
        }
        // Tear down our live chat session first so the dashboard's gateway
        // session releases its writer on the row before the dashboard delete
        // fires. Running both in parallel can produce FK errors or orphan messages.
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
        resetActiveStatus(id: id)
    }

    /// Clears an active turn state (`.working` or `.awaitingInput`) back to
    /// `.idle`. Shared by the turn-finished signal and the stream-close cleanup
    /// (`markIdle`) so both twin paths handle a session parked on a prompt
    /// identically — a reject/cancel that ends the turn, *and* a stream that
    /// dies while awaiting input, must both drop "needs you" rather than pin it.
    private func resetActiveStatus(id: SessionId) {
        switch statuses[id] {
        case .working, .awaitingInput:
            statuses[id] = .idle
        default:
            break
        }
    }

    /// The user answered the pending prompt; the turn resumes, so move
    /// `.awaitingInput` back to `.working`. A no-op for any other state.
    func markPermissionResolved(id: SessionId) {
        if case .awaitingInput = statuses[id] {
            statuses[id] = .working
        }
    }

    /// Session ids currently blocked on user input — drives the window-level
    /// aggregate badge so a background session that needs you is visible from
    /// any screen, even when its sidebar row isn't.
    var sessionsAwaitingInput: [SessionId] {
        openSessions
            .map(\.id)
            .filter { statuses[$0] == .awaitingInput }
    }

    // MARK: - Notifications

    /// Called by the chat VM when a user-started turn completes (the prompt
    /// success branch). Posts an "agent finished" banner unless the user is
    /// already watching this chat. `title` is the chat's current display name.
    func handleTurnCompleted(id: SessionId, title: String?) {
        guard let profileId, let notifier else { return }
        guard NotificationPolicy.shouldNotifyAgentFinished(
            settings: notifier.settings,
            isForeground: isWindowForeground,
            isSelected: selection == id
        ) else { return }
        notifier.postAgentFinished(profileId: profileId, sessionId: id, title: title ?? chatTitle(for: id))
    }

    /// Posts a "needs your input" banner for `id` unless the user is already
    /// watching this chat. Called from the `.permissionRequest` observer; the
    /// banner copy matches the in-app rendering per `kind` (approval / question /
    /// secret). The user's single "Tool approval needed" setting still gates all
    /// three, since each blocks the turn waiting on the user.
    private func notifyToolApproval(id: SessionId, kind: UserPromptKind, detail: String?) {
        guard let profileId, let notifier else { return }
        guard NotificationPolicy.shouldNotifyToolApproval(
            settings: notifier.settings,
            isForeground: isWindowForeground,
            isSelected: selection == id
        ) else { return }
        notifier.postToolApproval(
            profileId: profileId,
            sessionId: id,
            title: chatTitle(for: id),
            kind: kind,
            detail: detail
        )
    }

    /// The chat's display title from the open-session row or its cached view
    /// model, or nil if neither has a (non-empty) name yet.
    private func chatTitle(for id: SessionId) -> String? {
        normalizedTitle(openSessions.first(where: { $0.id == id })?.title)
            ?? normalizedTitle(viewModels[id]?.title)
    }

    /// Focuses the session a tapped notification points at: selects the tab if
    /// it's already open, otherwise opens it via the dashboard summary so the
    /// chat that prompted the notification comes to the front.
    func focusSession(route: NotificationRoute) {
        if openSessions.contains(where: { $0.id == route.sessionId }) {
            selection = route.sessionId
            return
        }
        Task {
            await openExisting(HermesSessionSummary(id: route.sessionId, title: route.title ?? ""))
        }
    }

    private func observe(id: SessionId, notification: HermesNotification) {
        switch notification {
        case let .permissionRequest(event):
            // Permission requests pause the turn waiting on the user — a
            // distinct "needs you" state, not the same green-dot `.working`
            // as ordinary agent work. Cleared by `markPermissionResolved`
            // when the user answers (or `markTurnFinished` on cancel).
            statuses[id] = .awaitingInput
            notifyToolApproval(id: id, kind: event.kind, detail: event.request.toolCall.title)
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
        resetActiveStatus(id: id)
    }
}
