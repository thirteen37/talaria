import HermesKit
import SwiftUI

struct ChatView: View {
    // The view model is owned by SessionsStore (keyed by sessionId) so it
    // survives view destruction — switching tabs no longer cancels the
    // in-flight prompt or loses the transcript.
    @Bindable var viewModel: LocalChatViewModel
    /// The window's store, forwarded so the toolbar can rename/delete/export the
    /// active session. Optional + defaulted so preview/test construction keeps
    /// compiling; the toolbar is gated on it being present.
    var store: SessionsStore? = nil

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    @State private var isExporting = false
    @State private var exportDocument: TranscriptDocument?
    /// Drives the inline permission card's focus ring + steals key input from the
    /// disabled composer when a prompt first appears.
    @FocusState private var promptFocused: Bool

    /// Scroll anchor for the inline permission card. A fixed string id (the card is
    /// a singleton tail element) so the on-show scroll can target it.
    private static let permissionAnchorID = "permission-prompt-anchor"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if viewModel.messages.isEmpty {
                            ContentUnavailableView("No Session", systemImage: "bubble.left.and.bubble.right")
                                .frame(maxWidth: .infinity, minHeight: 360)
                        } else {
                            let lastId = viewModel.messages.last?.id
                            ForEach(viewModel.messages) { message in
                                TranscriptRow(
                                    message: message,
                                    isLast: message.id == lastId,
                                    // Only the last row is actively growing while a
                                    // prompt is in flight — gate code highlighting on that.
                                    isStreaming: viewModel.isSending && message.id == lastId,
                                    onUndo: (message.isUndoableUserTurn && !viewModel.isReadOnly && !viewModel.isSending)
                                        ? { Task { await viewModel.undo(throughUserMessageId: message.id) } }
                                        : nil
                                )
                                .id(message.id)
                            }
                        }

                        // The blocking prompt renders inline as the transcript's
                        // tail element (not a modal sheet), so history stays
                        // scrollable while it's pending. It scrolls with the list;
                        // the persistent `permissionShortcuts` layer keeps ⌥N/Esc
                        // working even after it scrolls off-screen.
                        if let permission = viewModel.pendingPermission {
                            PermissionPrompt(
                                state: permission,
                                isFocused: $promptFocused,
                                select: { option in
                                    Task { await viewModel.resolvePermission(.selected(SelectedPermissionOutcome(optionId: option.optionId))) }
                                },
                                cancel: {
                                    Task { await viewModel.resolvePermission(.cancelled) }
                                }
                            )
                            .id(Self.permissionAnchorID)
                        }
                    }
                    .padding(16)
                }
                // Open at the bottom so a resumed session's seeded history shows
                // its most recent messages first. Done with an explicit one-shot
                // scroll (not `.defaultScrollAnchor(.bottom)`, which re-anchors on
                // *any* content-size change — including the last row's reflow at
                // turn end — and momentarily blanks the LazyVStack viewport). The
                // `onChange` below handles auto-scroll on later message changes.
                .task(id: viewModel.sessionId) {
                    // Re-assert the bottom scroll across a handful of frames. Under
                    // LazyVStack a long resumed transcript may not have materialized
                    // its last row within the first tick, so a lone scrollTo is a
                    // no-op that leaves the session opened at the top (unlike
                    // `.defaultScrollAnchor(.bottom)`, which positioned content
                    // before first paint regardless of list length). Retrying is
                    // cheap and idempotent — once the row exists the scroll lands,
                    // and re-targeting the current last id also covers incremental
                    // seeding. Bounded so it can't fight the user past initial open.
                    //
                    // A session can be reselected while a prompt is already pending
                    // (view models outlive their views), so `pendingPermission` may
                    // already be non-nil on appear — a case the `onChange` below
                    // never sees (it only fires on a transition). Reveal and focus
                    // the inline card here instead, reusing the same retry loop.
                    var focusedPrompt = false
                    for _ in 0 ..< 10 {
                        if viewModel.pendingPermission != nil {
                            proxy.scrollTo(Self.permissionAnchorID, anchor: .bottom)
                            if !focusedPrompt {
                                promptFocused = true
                                focusedPrompt = true
                            }
                        } else if let last = viewModel.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return // cancelled — session switched away
                        }
                    }
                }
                .onChange(of: viewModel.messages) { _, messages in
                    guard let last = messages.last else {
                        return
                    }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                // When a prompt first appears, focus its inline card and scroll it
                // into view. Runs after the `messages` onChange (the permission's
                // tool row also lands there), so it wins the final scroll position.
                // The one-frame sleep lets the lazy card materialize before the
                // scrollTo targets it (mirrors the open-at-bottom retry above).
                .onChange(of: viewModel.pendingPermission?.id) { _, id in
                    guard id != nil else {
                        return
                    }
                    promptFocused = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(16))
                        proxy.scrollTo(Self.permissionAnchorID, anchor: .bottom)
                    }
                }
            }

            StatusBar(
                statusText: viewModel.statusText,
                hasError: viewModel.hasError,
                isSending: viewModel.isSending,
                turnStartDate: viewModel.turnStartDate,
                model: viewModel.model,
                gitBranch: viewModel.gitBranch,
                contextUsed: viewModel.contextUsed,
                contextSize: viewModel.contextSize
            )

            if viewModel.isReadOnly {
                ReadOnlyComposerBanner()
            } else {
                Composer(
                    prompt: $viewModel.prompt,
                    isSending: viewModel.isSending,
                    isBlocked: viewModel.pendingPermission != nil,
                    blockedPlaceholder: viewModel.blockedPlaceholder,
                    availableCommands: viewModel.availableCommands,
                    send: { Task { await viewModel.sendPrompt() } },
                    cancel: { Task { await viewModel.cancel() } }
                )
            }
        }
        .navigationTitle(viewModel.title ?? "Chat")
        // Inline title (iOS) keeps the chat's vertical space for the transcript
        // instead of the tall large-title header; no-op on macOS.
        .inlineNavigationTitle()
        // Always-mounted, zero-size shortcut layer so ⌥N/Esc keep working even
        // after the inline card scrolls out of the recycling `LazyVStack`.
        .background { permissionShortcuts }
        // Per-session manage actions on the active chat's toolbar, plus their
        // rename sheet, delete confirmation, and JSONL exporter. All gate on
        // `store` internally, so the group is inert (toolbar empty) when no store
        // is in scope (preview/test construction).
        .toolbar { manageToolbarContent }
        .sheet(isPresented: $isRenaming) { renameSheet }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let store else { return }
                Task { await store.deleteSession(viewModel.sessionId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(sessionLabel)” and its transcript will be permanently deleted.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: TranscriptDocument.contentType,
            defaultFilename: "session-\(SessionIdFormatter.short(viewModel.sessionId)).jsonl"
        ) { _ in
            exportDocument = nil
        }
    }

    /// Hidden, always-mounted buttons that register the prompt's keyboard
    /// shortcuts window-wide: ⌥1…⌥9 select the corresponding option, Esc cancels.
    /// Mounted at the `VStack` level (not inside the card) so the shortcuts survive
    /// the card scrolling off-screen in the recycling `LazyVStack`. The composer is
    /// already disabled while a prompt is pending, so its `TextField` won't swallow
    /// the keys.
    @ViewBuilder
    private var permissionShortcuts: some View {
        if let permission = viewModel.pendingPermission {
            ZStack {
                Button("Cancel prompt") {
                    Task { await viewModel.resolvePermission(.cancelled) }
                }
                .keyboardShortcut(.cancelAction)

                // `.secret` has no selectable options (see `PermissionPrompt`), so
                // only Cancel is wired for it.
                if permission.kind != .secret {
                    ForEach(
                        Array(permission.request.options.prefix(PermissionPrompt.maxShortcutOptions).enumerated()),
                        id: \.element.optionId
                    ) { index, option in
                        Button("Select option \(index + 1)") {
                            Task { await viewModel.resolvePermission(.selected(SelectedPermissionOutcome(optionId: option.optionId))) }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .option)
                    }
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    /// The session's display name for confirmation copy — its title, or a short
    /// id when untitled.
    private var sessionLabel: String {
        let trimmed = viewModel.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? SessionIdFormatter.short(viewModel.sessionId) : trimmed
    }

    @ToolbarContentBuilder
    private var manageToolbarContent: some ToolbarContent {
        if let store {
            ToolbarItemGroup(placement: .primaryAction) {
                if store.supportsRename {
                    Button {
                        renameText = viewModel.title ?? ""
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .help("Rename this session")
                    .accessibilityLabel("Rename session")
                }

                Button {
                    Task {
                        guard let text = await store.transcriptJSONL(for: viewModel.sessionId) else {
                            return
                        }
                        exportDocument = TranscriptDocument(text: text)
                        isExporting = true
                    }
                } label: {
                    Label("Export Transcript", systemImage: "square.and.arrow.up")
                }
                .help("Export this session's transcript as JSONL")
                .accessibilityLabel("Export transcript")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete this session")
                .accessibilityLabel("Delete session")
            }
        }
    }

    @ViewBuilder
    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { isRenaming = false }
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    isRenaming = false
                    guard !trimmed.isEmpty, let store else {
                        return
                    }
                    Task { await store.renameSession(viewModel.sessionId, to: trimmed) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

private struct ReadOnlyComposerBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text("Read-only. Created outside Talaria; replies are not supported here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

@MainActor
@Observable
final class LocalChatViewModel {
    var prompt = ""
    var messages: [ChatTranscriptMessage] = []
    var isSending = false
    /// Hermes' auto-generated session title, written by `SessionsStore` from the
    /// agent → client `session_info_update`. Mirrors `OpenSession.title` so the
    /// chat header / window title (which only has the view model in scope) can
    /// show the real name instead of "Chat".
    var title: String?
    var statusText: String?
    var hasError = false
    var pendingPermission: PermissionPromptState?
    var availableCommands: [AvailableCommand] = []
    var gitBranch: String?
    /// Active model/mode alias reported by the gateway (`session.info`), shown
    /// as a badge in the status bar. Nil until the first session-info update.
    var model: String?
    var turnStartDate: Date?
    var contextUsed: Int?
    var contextSize: Int?
    let isReadOnly: Bool

    private weak var manager: SessionManager?
    private weak var store: SessionsStore?
    /// Exposed (not `private`) so the chat toolbar's manage actions and export
    /// filename can read it.
    let sessionId: SessionId
    private let cwd: String
    private var notificationTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private var currentUserStreamMessageId: UUID?
    private var currentAgentMessageId: UUID?
    private var currentThoughtMessageId: UUID?
    private var toolMessageIds: [ToolCallId: UUID] = [:]
    private var toolTitles: [ToolCallId: String] = [:]

    init(manager: SessionManager, sessionId: SessionId, cwd: String, store: SessionsStore? = nil) {
        self.manager = manager
        self.sessionId = sessionId
        self.cwd = cwd
        self.store = store
        self.isReadOnly = false
    }

    init(sessionId: SessionId, cwd: String, messages: [ChatTranscriptMessage], source: String) {
        self.manager = nil
        self.sessionId = sessionId
        self.cwd = cwd
        self.store = nil
        self.messages = messages
        self.statusText = "Read-only source: \(source)"
        self.isReadOnly = true
    }

    func start() async {
        guard !isReadOnly else {
            return
        }
        guard notificationTask == nil, let manager else {
            return
        }
        statusText = "Session cwd: \(cwd)"
        loadGitBranch()

        let stream = await manager.notifications(for: sessionId)
        notificationTask = Task { [weak self] in
            for await notification in stream {
                await self?.handle(notification: notification)
            }
        }
    }

    /// Re-subscribes after a reconnect re-resumed this session on a fresh
    /// manager session. When the previous WebSocket died the old notification
    /// stream finished and `notificationTask` exited permanently; clear it and
    /// re-`start()`, which re-attaches to the new session (whose
    /// `SessionManager.addSubscriber` replays any buffered history). Clears
    /// `hasError` so a stale "connection lost" notice doesn't linger.
    func restart() async {
        guard !isReadOnly else {
            return
        }
        notificationTask?.cancel()
        notificationTask = nil
        hasError = false
        await start()
    }

    /// Marks this session lost after a reconnect found no resumable server-side
    /// session to re-attach to (a brand-new chat the gateway never persisted).
    /// Surfaces an inline notice *without* blanking `messages`, so whatever the
    /// user had on screen stays readable.
    func markConnectionLost() {
        hasError = true
        statusText = "Connection lost — start a new chat to continue."
    }

    func sendPrompt() async {
        guard !isReadOnly else {
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // A parked permission overlay blocks every send, idle or busy. Empty
        // input is always a no-op.
        guard !text.isEmpty, pendingPermission == nil else {
            return
        }
        guard let manager, let client = await manager.client(for: sessionId) else {
            hasError = true
            statusText = "Session is not active"
            return
        }

        // While a turn is in flight we only accept the gateway's pending-input
        // set: a slash in `SlashCommand.pendingInputCommands`, or plain text
        // auto-wrapped as `/queue …`. Everything else is a no-op so a second
        // normal turn can never race the live one.
        if isSending {
            await sendWhileBusy(text: text, client: client)
            return
        }

        // A `/`-prefixed message is a slash command — it's run by the harness (or
        // a native Talaria action), never sent to the LLM. Echo the typed command
        // as a user bubble, then route it.
        if text.hasPrefix("/") {
            prompt = ""
            _ = append(kind: .user, text: text)
            let parsed = SlashCommand(parsing: text)
            // Mark the session busy for the duration of the slash dispatch: it
            // drives the working indicator and, crucially, the `isSending` guard
            // above blocks a second send from starting a normal turn that would
            // race the slash `.submit` path's `runPrompt` (→ `turnInProgress`).
            // Tradeoff: `isSending` also shows the composer's Cancel button, which
            // is inert while a non-`.submit` slash RPC (e.g. /help) is in flight —
            // the gateway has no slash-cancel RPC and `call(...)` isn't
            // cancellable, so `cancel()` can't abort it. Left as-is deliberately:
            // slash RPCs resolve quickly and the dispatch's own completion clears
            // `isSending` (the `.submit` case does produce a real cancellable turn).
            isSending = true
            turnStartDate = Date()
            statusText = "Running /\(parsed.name)…"
            hasError = false
            store?.markTurnStarted(id: sessionId)

            // `runSlash` returns true when it handed off to `runPrompt` (the
            // `.submit` case), which then owns the busy lifecycle; otherwise we
            // clear it here.
            let startedTurn = await runSlash(name: parsed.name, arg: parsed.arg, client: client)
            if !startedTurn {
                isSending = false
                turnStartDate = nil
                statusText = nil
                store?.markTurnFinished(id: sessionId)
            }
            return
        }

        prompt = ""
        await runPrompt(text: text, client: client, echoUser: true)
    }

    /// `UserDefaults` flag (per user, not per session/profile) gating the one-time
    /// auto-queue explainer.
    static let autoQueueTipShownKey = "chat.autoQueueTipShown"

    /// Handles a send issued while a turn is already streaming. Accepts only the
    /// gateway's pending-input commands: a slash in
    /// ``SlashCommand/pendingInputCommands``, or plain text auto-wrapped as
    /// `/queue …`. Crucially it does **not** touch the live turn's busy state
    /// (`isSending`, `turnStartDate`, `statusText`, `markTurnStarted`) — the
    /// running turn owns those — and surfaces feedback as an inline `.event`
    /// line rather than a new user bubble, so the streaming transcript stays clean.
    private func sendWhileBusy(text: String, client: any ChatBackend) async {
        let name: String
        let arg: String
        let isAutoQueue: Bool
        if text.hasPrefix("/") {
            let parsed = SlashCommand(parsing: text)
            guard parsed.isPendingInput else {
                // A non-pending-input slash (/help, /model, …) while busy is a
                // no-op: dispatching it would be inert at best and confusing at
                // worst. Leave the composer text so the user can resend later.
                return
            }
            name = parsed.name
            arg = parsed.arg
            isAutoQueue = false
        } else {
            // Plain text mid-turn → queue it for after the current turn, so the
            // user doesn't have to know the `/queue` verb.
            name = "queue"
            arg = text
            isAutoQueue = true
        }

        prompt = ""
        if isAutoQueue {
            appendAutoQueueFeedback()
        } else if let marker = Self.busyDispatchMarker(name: name, arg: arg) {
            append(kind: .event, text: marker)
        }
        // `whileBusy` keeps the dispatch from starting a second turn and skips the
        // empty-output placeholder (our marker is the feedback). The live turn's
        // busy lifecycle is untouched.
        _ = await runHarnessSlash(name: name, arg: arg, client: client, whileBusy: true)
    }

    /// Immediate confirmation line for an explicit pending-input slash sent
    /// mid-turn. Returns `nil` for the no-argument / non-confirmable forms
    /// (`/queue` listing, `/retry`, `/undo`) so the gateway's own output is the
    /// only line shown for those.
    private static func busyDispatchMarker(name: String, arg: String) -> String? {
        guard !arg.isEmpty else {
            return nil
        }
        switch name.lowercased() {
        case "queue", "q": return "Queued: \(arg)"
        case "steer": return "Steering: \(arg)"
        case "plan": return "Plan: \(arg)"
        case "goal": return "Goal: \(arg)"
        default: return nil
        }
    }

    /// Appends the auto-queue feedback line: a one-time explainer the first time a
    /// user auto-queues (then never again), and a terse "Queued." afterwards.
    private func appendAutoQueueFeedback() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.autoQueueTipShownKey) {
            append(kind: .event, text: "Queued.")
        } else {
            append(
                kind: .event,
                text: "Queued — Hermes will send this after the current turn. "
                    + "Tip: prefix with /queue to be explicit, or /steer to inject guidance mid-turn."
            )
            defaults.set(true, forKey: Self.autoQueueTipShownKey)
        }
    }

    #if DEBUG
    /// Re-arms the one-time auto-queue tip so manual QA can see it again. Not
    /// exposed in the UI.
    static func resetAutoQueueTip() {
        UserDefaults.standard.removeObject(forKey: autoQueueTipShownKey)
    }
    #endif

    /// Counts the real user turns from `id` (inclusive) back to the latest, so an
    /// "undo back to here" can dispatch a single `/undo <N>`: the latest user
    /// bubble → 1, the one before → 2, and so on. Locally echoed slash commands
    /// are skipped (see ``ChatTranscriptMessage/isUndoableUserTurn``) so the count
    /// matches Hermes' real turn boundaries rather than inflating `N`. Returns 0
    /// if `id` isn't found. Pure and `nonisolated` so it's unit-testable from a
    /// synchronous, non-`MainActor` context (the class itself is `@MainActor`).
    nonisolated static func undoTurnCount(through id: UUID, in messages: [ChatTranscriptMessage]) -> Int {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return 0
        }
        return messages[index...].reduce(0) { $0 + ($1.isUndoableUserTurn ? 1 : 0) }
    }

    /// Rewinds the conversation back to a user bubble by running `/undo <N>`,
    /// where `N` is the number of user turns from that bubble to the latest. Unlike
    /// the composer slash path, this does *not* echo a `/undo` user bubble — the
    /// `.prefill` outcome in `runHarnessSlash` already re-seeds the transcript and
    /// surfaces the harness notice.
    func undo(throughUserMessageId id: UUID) async {
        guard !isReadOnly, !isSending, pendingPermission == nil else {
            return
        }
        guard let manager else {
            hasError = true
            statusText = "Session is not active"
            return
        }
        let count = Self.undoTurnCount(through: id, in: messages)
        guard count > 0 else {
            return
        }
        // Mark the session busy *before* the first `await` so a rapid second Undo
        // tap fails the `!isSending` guard above instead of slipping past it and
        // rewinding extra turns from the same not-yet-refreshed `messages`
        // (mirrors the composer slash path). `/undo` resolves as `.prefill`, never
        // `.submit`, so no turn is started and we own this busy lifecycle — the
        // `defer` restores it on every exit, including the no-client path.
        isSending = true
        turnStartDate = Date()
        statusText = "Running /undo…"
        hasError = false
        store?.markTurnStarted(id: sessionId)
        defer {
            isSending = false
            turnStartDate = nil
            store?.markTurnFinished(id: sessionId)
        }
        guard let client = await manager.client(for: sessionId) else {
            hasError = true
            statusText = "Session is not active"
            return
        }
        // count == 1 → plain "/undo" (the already-verified shape); >1 passes the count.
        _ = await runHarnessSlash(name: "undo", arg: count > 1 ? String(count) : "", client: client)
    }

    /// Runs one LLM turn. `echoUser` appends the user bubble for a normal send;
    /// the slash `submit` path passes `false` because the command was already
    /// echoed. Extracted so both callers share the streaming/turn lifecycle.
    private func runPrompt(text: String, client: any ChatBackend, echoUser: Bool) async {
        resetStreamingMessages()
        if echoUser {
            currentUserStreamMessageId = append(kind: .user, text: text)
        }
        isSending = true
        turnStartDate = Date()
        statusText = "Hermes is working in \(cwd)..."
        hasError = false
        store?.markTurnStarted(id: sessionId)

        let id = sessionId
        promptTask = Task { [weak self] in
            do {
                let response = try await client.prompt(sessionId: id, content: text)
                self?.statusText = "Stopped: \(response.stopReason.rawValue)"
                // Only the success branch is a real turn completion —
                // cancellation and errors take the catch paths below — so notify
                // here (gated by the store's policy + foreground/selection).
                if let self {
                    self.store?.handleTurnCompleted(id: id, title: self.title)
                }
            } catch is CancellationError {
                self?.statusText = "Cancelled"
            } catch {
                self?.hasError = true
                self?.statusText = self?.errorMessage(for: error)
            }
            self?.isSending = false
            self?.turnStartDate = nil
            self?.store?.markTurnFinished(id: id)
        }
    }

    /// Routes a parsed slash command: native shims (real Talaria actions),
    /// informational stubs (honest "not supported here" lines), or the harness.
    /// Returns `true` only when it delegated to ``runPrompt`` (the harness
    /// `.submit` case), so the caller knows the busy lifecycle has been handed
    /// off rather than completing inline.
    private func runSlash(name: String, arg: String, client: any ChatBackend) async -> Bool {
        switch name.lowercased() {
        // A. Native shims — real Talaria actions.
        case "new", "reset":
            // No transcript confirmation: on success `openNew` switches selection
            // to a fresh empty session (the visible feedback), and on failure it
            // swallows the error into `store.lastError` and stays put — so a
            // "Started a new session." line would either land on the now-hidden
            // old session or falsely claim success. This matches the toolbar
            // new-session button, which likewise just calls `openNew()`.
            await store?.openNew()
        case "title":
            if arg.isEmpty {
                append(kind: .event, text: title.map { "Current title: \($0)" } ?? "This session has no title yet.")
            } else {
                await runSetTitle(to: arg, client: client)
            }

        // B. Informational stubs — capabilities Talaria doesn't have, intercepted
        // so they neither hit the LLM nor create confusing harness state.
        case "yolo":
            append(kind: .event, text: "Approval bypass isn't available in Talaria — approvals are interactive here.")
        case "profile":
            append(kind: .event, text: "This window is bound to a single Hermes profile. Open a new window to use another profile.")
        case "skin":
            append(kind: .event, text: "Talaria follows the system appearance; skins aren't supported.")
        case "branch", "fork":
            append(kind: .event, text: "Session branching isn't supported in Talaria yet.")

        // C. Everything else → harness.
        default:
            return await runHarnessSlash(name: name, arg: arg, client: client)
        }
        return false
    }

    private func runSetTitle(to newTitle: String, client: any ChatBackend) async {
        do {
            let resolved = try await client.setTitle(sessionId: sessionId, title: newTitle)
            // The gateway echoes the persisted title, but an unpersisted/pending
            // row can come back blank. Honor the same never-blank invariant
            // `applyTitle`/`updateTitle` enforce by falling back to the requested
            // (non-blank) title, and feed the *same* value to the header and the
            // store so they can't diverge.
            let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
            let applied = trimmed.isEmpty ? newTitle : trimmed
            title = applied
            store?.updateTitle(sessionId, to: applied)
            append(kind: .event, text: "Renamed session to “\(applied)”.")
        } catch {
            append(kind: .event, text: errorMessage(for: error))
        }
    }

    /// Runs a command through the harness. Returns `true` only for the `.submit`
    /// case, where it delegates to ``runPrompt`` (which owns the busy lifecycle).
    ///
    /// `whileBusy` marks a pending-input dispatch sent over a live turn: it skips
    /// the empty-output placeholder (the caller already appended a marker) and
    /// refuses a `.submit` outcome — a pending-input command must never start a
    /// second turn over the running one (defensive; Hermes returns `exec`/`output`
    /// for the pending-input set, not `send`).
    private func runHarnessSlash(name: String, arg: String, client: any ChatBackend, whileBusy: Bool = false) async -> Bool {
        let command = arg.isEmpty ? name : "\(name) \(arg)"
        do {
            switch try await client.slash(sessionId: sessionId, command: command) {
            case let .output(text):
                if text.isEmpty {
                    if !whileBusy {
                        append(kind: .event, text: "(no output)")
                    }
                } else {
                    append(kind: .event, text: text)
                }
            case let .prefill(message, notice):
                if whileBusy {
                    // The `/undo` rewind shape arrived mid-turn (undo is in the
                    // pending-input set). Running the idle path below would
                    // clobber the live turn — refilling the composer the busy
                    // path just cleared and replacing the streaming transcript
                    // mid-stream — violating `sendWhileBusy`'s invariant. Surface
                    // only the harness's notice and leave prompt/transcript intact.
                    if !notice.isEmpty {
                        append(kind: .event, text: notice)
                    }
                    return false
                }
                prompt = message
                // This is the `/undo` shape: the harness rewound the transcript
                // server-side. Re-seed our local transcript from the dashboard's
                // authoritative message list (one `GET /api/sessions/{id}`, no
                // re-resume) so it matches — dropping the undone turn — instead of
                // guessing what to trim from the human-text notice. Then surface
                // the notice as confirmation. (No-ops for a brand-new session not
                // yet keyed by a stored dashboard id; see `refreshTranscript`.)
                await store?.refreshTranscript(sessionId)
                if !notice.isEmpty {
                    append(kind: .event, text: notice)
                }
            case let .submit(message, notice):
                if whileBusy {
                    // A pending-input dispatch must never start a turn over the
                    // live one. Hermes shouldn't return `send` for the
                    // pending-input set, so treat it as an error rather than
                    // silently launching a racing turn.
                    append(kind: .event, text: "Couldn't send while the current turn is running.")
                    return false
                }
                if let notice, !notice.isEmpty {
                    append(kind: .event, text: notice)
                }
                await runPrompt(text: message, client: client, echoUser: false)
                return true
            }
        } catch {
            append(kind: .event, text: errorMessage(for: error))
        }
        return false
    }

    func cancel() async {
        guard !isReadOnly else {
            return
        }
        promptTask?.cancel()

        if pendingPermission != nil {
            await resolvePermission(.cancelled)
        }

        guard let manager, let client = await manager.client(for: sessionId) else {
            isSending = false
            turnStartDate = nil
            statusText = "Cancelled"
            return
        }

        do {
            try await client.cancel(sessionId: sessionId)
            statusText = "Cancellation requested"
        } catch {
            hasError = true
            statusText = errorMessage(for: error)
        }
    }

    func resolvePermission(_ outcome: PermissionOutcome) async {
        guard let permission = pendingPermission else {
            return
        }

        pendingPermission = nil
        // Single choke point for every prompt resolution (allow/deny, and
        // cancel() which routes through `.cancelled`): move the session out of
        // `.awaitingInput` so the sidebar/window badge clears as the turn
        // resumes. `markTurnFinished` still handles the turn-ending cases.
        store?.markPermissionResolved(id: sessionId)
        applyLocalToolStatus(for: outcome, permission: permission)
        await permission.respond(outcome)
        statusText = "Permission response sent"
    }

    private func applyLocalToolStatus(for outcome: PermissionOutcome, permission: PermissionPromptState) {
        let toolCallId = permission.request.toolCall.toolCallId
        switch outcome {
        case .cancelled:
            setToolStatus(.failed, for: toolCallId)
        case let .selected(selection):
            guard let option = permission.request.options.first(where: { $0.optionId == selection.optionId }) else {
                return
            }
            switch option.kind {
            case .allowOnce, .allowAlways:
                setToolStatus(nil, for: toolCallId)
            case .rejectOnce, .rejectAlways:
                setToolStatus(.failed, for: toolCallId)
            }
        case .raw:
            return
        }
    }

    private func setToolStatus(_ status: ToolCallStatus?, for toolCallId: ToolCallId) {
        guard let messageId = toolMessageIds[toolCallId],
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        let displayTitle = messages[index].toolTitle ?? toolTitles[toolCallId] ?? toolCallId
        messages[index].toolStatus = status
        messages[index].text = [displayTitle, status.map { "(\($0.rawValue))" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    func shutdown() async {
        notificationTask?.cancel()
        notificationTask = nil
        promptTask?.cancel()
        if pendingPermission != nil {
            await resolvePermission(.cancelled)
        }
        isSending = false
        turnStartDate = nil
        resetStreamingMessages()
    }

    private func loadGitBranch() {
        let cwd = cwd
        Task {
            gitBranch = await GitInfo.branch(cwd: cwd)
        }
    }

    private func handle(notification: HermesNotification) async {
        switch notification {
        case let .sessionUpdate(notification):
            guard notification.sessionId == sessionId else {
                return
            }
            handle(sessionUpdate: notification.update)
        case let .permissionRequest(event):
            guard event.request.sessionId == sessionId else {
                return
            }
            handle(permissionRequest: event)
        case let .clientRequestError(_, method, message):
            hasError = true
            statusText = "\(method) response failed: \(message)"
        case let .raw(method, _):
            resetStreamingMessages()
            append(kind: .event, text: method)
        case let .request(id, method, _):
            resetStreamingMessages()
            append(kind: .event, text: "Unsupported Hermes request: \(method)")
            if let client = await manager?.client(for: sessionId) {
                try? await client.respond(
                    id: id,
                    error: JSONRPCError(code: -32601, message: "Talaria does not support \(method) yet")
                )
            }
        }
    }

    private func handle(sessionUpdate update: SessionUpdate) {
        switch update {
        case let .userMessageChunk(chunk):
            appendStreaming(kind: .user, text: chunk.content.plainText ?? "", stream: .user)
        case let .agentMessageChunk(chunk):
            appendStreaming(kind: .agent, text: chunk.content.plainText ?? "", stream: .agent)
        case let .agentThoughtChunk(chunk):
            appendStreaming(kind: .thought, text: chunk.content.plainText ?? "", stream: .thought)
        case let .toolCall(toolCall):
            resetStreamingMessages()
            upsertToolMessage(
                id: toolCall.toolCallId,
                title: toolCall.title,
                status: toolCall.status,
                content: toolCall.content
            )
        case let .toolCallUpdate(update):
            resetStreamingMessages()
            upsertToolMessage(
                id: update.toolCallId,
                title: update.title,
                status: update.status,
                content: update.content
            )
        case let .availableCommandsUpdate(update):
            availableCommands = update.availableCommands
        case let .usageUpdate(update):
            contextUsed = update.used
            contextSize = update.size
        case let .sessionInfoUpdate(update):
            if let model = update.model, !model.isEmpty {
                self.model = model
            }
            // Prefer the gateway's branch when present — it's authoritative for
            // remote sessions, where the local `GitInfo` probe of the cwd is wrong.
            if let branch = update.branch, !branch.isEmpty {
                gitBranch = branch
            }
        default:
            if let text = update.displayText {
                resetStreamingMessages()
                append(kind: .event, text: text)
            }
        }
    }

    private func handle(permissionRequest event: PermissionRequestEvent) {
        resetStreamingMessages()
        upsertToolMessage(
            id: event.request.toolCall.toolCallId,
            title: event.request.toolCall.title,
            status: event.request.toolCall.status ?? .pending,
            content: event.request.toolCall.content
        )
        pendingPermission = PermissionPromptState(id: event.id, request: event.request, kind: event.kind) { outcome in
            await event.respond(outcome)
        }
        statusText = Self.waitingText(for: event.kind)
    }

    /// The "waiting on the user" copy for a blocking prompt, shared by the status
    /// line and the composer placeholder so the two can't drift apart.
    static func waitingText(for kind: UserPromptKind) -> String {
        switch kind {
        case .question: "Waiting for your answer"
        case .secret: "Waiting for input"
        case .permission: "Waiting for permission"
        }
    }

    /// Placeholder shown in the disabled composer while a prompt blocks input —
    /// matches the status line's per-kind copy (falls back to permission wording
    /// when nothing is pending).
    var blockedPlaceholder: String {
        Self.waitingText(for: pendingPermission?.kind ?? .permission)
    }

    @discardableResult
    private func append(kind: ChatTranscriptMessage.Kind, text: String, toolCallId: ToolCallId? = nil) -> UUID? {
        guard !text.isEmpty else {
            return nil
        }
        let message = ChatTranscriptMessage(kind: kind, text: text, toolCallId: toolCallId)
        messages.append(message)
        return message.id
    }

    private func appendStreaming(kind: ChatTranscriptMessage.Kind, text: String, stream: StreamKind) {
        guard !text.isEmpty else {
            return
        }

        if let id = currentMessageId(for: stream),
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
            return
        }

        let id = append(kind: kind, text: text)
        setCurrentMessageId(id, for: stream)
    }

    private func upsertToolMessage(
        id toolCallId: ToolCallId,
        title: String?,
        status: ToolCallStatus?,
        content: [ToolCallContent]?
    ) {
        if let title {
            toolTitles[toolCallId] = title
        }

        let displayTitle = title ?? toolTitles[toolCallId] ?? toolCallId
        let text = [displayTitle, status.map { "(\($0.rawValue))" }]
            .compactMap { $0 }
            .joined(separator: " ")

        if let messageId = toolMessageIds[toolCallId],
           let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].text = text
            messages[index].toolTitle = displayTitle
            if let status {
                messages[index].toolStatus = status
            }
            if let content {
                messages[index].toolContent = content
            }
        } else {
            let message = ChatTranscriptMessage(
                kind: .tool,
                text: text,
                toolCallId: toolCallId,
                toolTitle: displayTitle,
                toolStatus: status,
                toolContent: content ?? []
            )
            messages.append(message)
            toolMessageIds[toolCallId] = message.id
        }
    }

    private func currentMessageId(for stream: StreamKind) -> UUID? {
        switch stream {
        case .user: currentUserStreamMessageId
        case .agent: currentAgentMessageId
        case .thought: currentThoughtMessageId
        }
    }

    private func setCurrentMessageId(_ id: UUID?, for stream: StreamKind) {
        switch stream {
        case .user: currentUserStreamMessageId = id
        case .agent: currentAgentMessageId = id
        case .thought: currentThoughtMessageId = id
        }
    }

    private func resetStreamingMessages() {
        currentUserStreamMessageId = nil
        currentAgentMessageId = nil
        currentThoughtMessageId = nil
    }

    /// Replaces the transcript with a fresh seed (e.g. after a harness-side
    /// rewind from `/undo`) and clears the streaming/tool-tracking caches that
    /// pointed at the now-removed messages.
    func replaceTranscript(with messages: [ChatTranscriptMessage]) {
        self.messages = messages
        resetStreamingMessages()
        toolMessageIds.removeAll()
        toolTitles.removeAll()
    }

    private func errorMessage(for error: Error) -> String {
        // GatewayChatError / GatewayWebSocketError are LocalizedError, so their
        // descriptions surface here automatically.
        error.localizedDescription
    }
}
