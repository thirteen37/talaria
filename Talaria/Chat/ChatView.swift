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

    /// Page Up / Page Down scroll-back. The composer's page-key closures set
    /// `pendingScroll`; the `onChange` scroller inside the `ScrollViewReader`
    /// consumes it. `pageAnchorIndex` remembers the last keyboard-driven anchor so
    /// repeated presses walk the transcript instead of re-jumping to the bottom.
    @State private var pendingScroll: ScrollDirection?
    @State private var pageAnchorIndex: Int?

    /// Scroll anchor for the inline permission card. A fixed string id (the card is
    /// a singleton tail element) so the on-show scroll can target it.
    private static let permissionAnchorID = "permission-prompt-anchor"

    var body: some View {
        VStack(spacing: 0) {
            // A GeometryReader captures the chat pane's width so each transcript
            // row can be given a *definite* width (see `rowWidth`). Without it,
            // every row's markdown is flexible (`maxWidth: .infinity`), which puts
            // SwiftUI's stack layout on its expensive general "probe children with
            // many proposals" path. MarkdownUI nests stacks deeply (lists, inline
            // runs, code), so that probing grows exponentially with depth and never
            // converges when the LazyVStack re-measures earlier rows on scroll-up —
            // permanently freezing the app. A rigid width collapses it to one
            // linear pass.
            GeometryReader { geo in
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
                                    .frame(width: rowWidth(for: geo.size.width), alignment: .leading)
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
                    // New content re-anchors paging to the live bottom, so the next
                    // Page Up resumes from the latest message rather than a stale
                    // mid-transcript index.
                    pageAnchorIndex = nil
                    guard let last = messages.last else {
                        return
                    }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                // Page Up / Page Down (from the composer) walk the transcript by a
                // fixed message stride. The anchor is *tracked*, not read from the
                // live scroll position (macOS 14 lacks the offset-based
                // `ScrollPosition` API, and mixing `.scrollPosition(id:)` with the
                // imperative auto-scroll risks the fragile relayout #151 fixed), so
                // a trackpad scroll between key presses makes the first Page key
                // resume from the last keyboard anchor. Acceptable for v1.
                .onChange(of: pendingScroll) { _, direction in
                    guard let direction else { return }
                    defer { pendingScroll = nil }
                    guard let target = Self.pagedAnchorIndex(
                        from: pageAnchorIndex,
                        direction: direction,
                        count: viewModel.messages.count
                    ) else { return }
                    let message = viewModel.messages[target]
                    let isLast = target == viewModel.messages.count - 1
                    // Land the last row on `.bottom` so Page Down returns cleanly to
                    // the live tail; every earlier anchor lands on `.top`.
                    proxy.scrollTo(message.id, anchor: isLast ? .bottom : .top)
                    pageAnchorIndex = target
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

            // Live `/bg` status stack (desktop parity). Event-driven: tasks start
            // running on `prompt.background` and flip finished on `background.complete`.
            BackgroundTasksIndicator(tasks: viewModel.backgroundTasks)

            if viewModel.isReadOnly {
                ReadOnlyComposerBanner()
            } else {
                Composer(
                    prompt: $viewModel.prompt,
                    attachments: $viewModel.attachments,
                    isSending: viewModel.isSending,
                    isBlocked: viewModel.pendingPermission != nil,
                    blockedPlaceholder: viewModel.blockedPlaceholder,
                    availableCommands: viewModel.availableCommands,
                    send: { Task { await viewModel.sendPrompt() } },
                    cancel: { Task { await viewModel.cancel() } },
                    onPageUp: { pendingScroll = .up },
                    onPageDown: { pendingScroll = .down }
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

    /// The definite width handed to each transcript row, derived from the scroll
    /// pane's width minus the `LazyVStack`'s 16pt horizontal insets on each side.
    /// Clamped to a small floor so a transient 0-width geometry pass (before first
    /// layout) never produces a negative frame.
    private func rowWidth(for containerWidth: CGFloat) -> CGFloat {
        max(containerWidth - 32, 1)
    }

    /// Page Up / Page Down scroll direction.
    enum ScrollDirection { case up, down }

    /// Messages stepped per Page Up / Page Down. A rough stride — transcript rows
    /// vary in height, so a fixed message count only approximates a "page" (see the
    /// tracked-anchor limitation at the scroll call site).
    nonisolated static let transcriptPageStride = 5

    /// Next page-scroll anchor index: steps `current` (nil → the last message) by
    /// `stride` in `direction`, clamped into `0..<count`. Returns nil for an empty
    /// transcript. Pure and `nonisolated` so it's unit-testable off the `@MainActor`.
    nonisolated static func pagedAnchorIndex(
        from current: Int?,
        direction: ScrollDirection,
        count: Int,
        stride: Int = transcriptPageStride
    ) -> Int? {
        guard count > 0 else { return nil }
        let start = current ?? (count - 1)
        let step = direction == .up ? -stride : stride
        return min(max(start + step, 0), count - 1)
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

/// Compact live indicator for `/bg` background tasks — "🌘 N running" with a
/// popover listing them. Hidden when nothing is running (the per-task result
/// also lands in the transcript). Event-driven; see ``LocalChatViewModel``.
private struct BackgroundTasksIndicator: View {
    let tasks: [LocalChatViewModel.BackgroundTask]
    @State private var showingPopover = false

    private var running: [LocalChatViewModel.BackgroundTask] {
        tasks.filter { $0.state == .running }
    }

    var body: some View {
        if !running.isEmpty {
            HStack {
                Spacer(minLength: 0)
                Button {
                    showingPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "moonphase.waning.crescent")
                        Text("\(running.count) running")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .help("\(running.count) background task\(running.count == 1 ? "" : "s") running — show details")
                .accessibilityLabel("Background tasks")
                .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                    BackgroundTasksList(tasks: running)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// The popover body listing the running `/bg` tasks and their prompts.
private struct BackgroundTasksList: View {
    let tasks: [LocalChatViewModel.BackgroundTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background tasks")
                .font(.headline)
            ForEach(tasks) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(task.text)
                        .font(.callout)
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 240, maxWidth: 360, alignment: .leading)
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
    /// One `/bg` background task, tracked for the live status indicator.
    struct BackgroundTask: Identifiable, Equatable {
        let id: String
        let text: String
        var state: State
        enum State: Equatable { case running, finished }
    }

    var prompt = ""
    /// Images staged in the composer for the next turn. Sent (and echoed in the
    /// user bubble) on a normal idle send; left staged across slash/busy sends,
    /// which stay text-only. Cleared on dispatch, not on success — the echoed
    /// bubble preserves what was sent.
    var attachments: [ComposerAttachment] = []
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
    /// `/bg` tasks started this session, for the live status indicator. A task is
    /// added (running) when `prompt.background` returns its id and flipped to
    /// finished on the matching `background.complete`. Purely event-driven: there's
    /// no `process.list` reconcile, because `/bg` AIAgent tasks don't surface in
    /// the OS process registry, so the gateway has nothing to reconcile against. A
    /// dropped `background.complete` would leave a task shown as running (benign —
    /// the result still lands in the transcript when it arrives).
    private(set) var backgroundTasks: [BackgroundTask] = []
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
    /// The detached `/handoff` poll, so it can be cancelled on shutdown / when a
    /// newer handoff supersedes it. Runs off the turn-busy state by design (see
    /// ``runHandoff(platform:client:)``).
    private var handoffPollTask: Task<Void, Never>?
    /// Plain text / `/queue`d messages the user sent mid-turn, held until the
    /// current turn ends *cleanly* and then submitted one at a time (FIFO). A
    /// cancel/error halts the drain (the items persist and resume after the next
    /// clean turn). See ``drainNextQueuedPrompt(client:)``.
    private var queuedPrompts: [String] = []
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
        let id = sessionId
        notificationTask = Task { [weak self] in
            for await notification in stream {
                await self?.handle(notification: notification)
            }
            // The notification stream ended. Intentional teardown (`shutdown()` /
            // `restart()`) cancels this task first, so a non-cancelled exit means
            // the live WebSocket died out from under a session meant to be alive —
            // the macOS silent-WS-death case (no background→foreground hook to
            // recover it). Ask the store to recover the connection.
            if !Task.isCancelled {
                self?.store?.handleLiveSessionDied(id: id)
            }
        }
    }

    /// Cancels the live notification subscription *without* the `restart()`
    /// re-subscribe or `shutdown()` turn-state teardown. ``SessionsStore`` calls
    /// this before it deliberately closes a still-live manager session during a
    /// full ``SessionsStore/recoverLiveSessions(limitedTo:)`` re-resume, so the
    /// resulting stream-end is observed as *cancelled* (intentional) and doesn't
    /// spuriously trip ``SessionsStore/handleLiveSessionDied(id:)`` for a session
    /// that's being recovered, not dying. A no-op once the task has exited.
    func suspendNotifications() {
        notificationTask?.cancel()
        notificationTask = nil
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
        // input — no text *and* no staged image — is always a no-op.
        guard !text.isEmpty || !attachments.isEmpty, pendingPermission == nil else {
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
        // normal turn can never race the live one. Mid-turn sends are text-only
        // (images can't ride a queue/steer), so an attachment-only send while
        // busy is a no-op — the images stay staged for the next idle turn.
        if isSending {
            guard !text.isEmpty else { return }
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

        // Normal idle send: text and/or staged images. Capture the attachments,
        // clear both composer fields on dispatch, and run a content-aware turn.
        let outgoing = attachments
        prompt = ""
        attachments = []
        await runPrompt(text: text, attachments: outgoing, client: client, echoUser: true)
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
            // Background commands run concurrently — dispatch immediately rather
            // than queueing (concurrency is the whole point), and never touch the
            // live turn's busy state.
            if parsed.isBackground {
                prompt = ""
                await startBackgroundPrompt(text: parsed.arg, client: client)
                return
            }
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

    /// Text-only turn. Thin wrapper over the content-aware core so the slash
    /// `.submit` handoff and ``drainNextQueuedPrompt(client:)`` stay image-free.
    private func runPrompt(text: String, client: any ChatBackend, echoUser: Bool) async {
        await runPrompt(text: text, attachments: [], client: client, echoUser: echoUser)
    }

    /// Runs one LLM turn carrying text and/or staged images. `echoUser` appends
    /// the user bubble (with thumbnails of `attachments`) for a normal send; the
    /// slash `submit` path passes `false` because the command was already echoed.
    /// Extracted so both callers share the streaming/turn lifecycle.
    private func runPrompt(
        text: String,
        attachments: [ComposerAttachment],
        client: any ChatBackend,
        echoUser: Bool
    ) async {
        resetStreamingMessages()
        if echoUser {
            currentUserStreamMessageId = append(kind: .user, text: text, images: attachments.map(\.data))
        }
        // Build the content: the text block (omitted when empty so an image-only
        // turn submits `text == ""`) plus one image block per staged attachment.
        var content: [ContentBlock] = []
        if !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: attachments.map { $0.contentBlock() })
        isSending = true
        turnStartDate = Date()
        statusText = "Hermes is working in \(cwd)..."
        hasError = false
        store?.markTurnStarted(id: sessionId)
        // Arm the "agent finished" notification *only* here, the genuine LLM-turn
        // path (direct send + the `.submit` slash handoff) — not from every
        // `markTurnStarted` caller, since non-turn busy states (/help, /undo)
        // would arm without a turn to consume it. See `armAgentFinished`.
        store?.armAgentFinished(id: sessionId)

        let id = sessionId
        promptTask = Task { [weak self] in
            // Only a clean (non-cancelled, non-error) completion drains the next
            // queued prompt; a cancel/error halts the drain and leaves the queue
            // intact for the next clean turn.
            var completedCleanly = false
            do {
                let response = try await client.prompt(sessionId: id, content: content)
                self?.statusText = "Stopped: \(response.stopReason.rawValue)"
                // The "agent finished" notification is no longer fired here: the
                // prompt resolves on the *first* `message.complete`, but Hermes
                // chains continuation turns after it, so firing here lands the
                // banner at the start of the final response. It's now event-driven
                // and debounced in `SessionsStore` (armed by `armAgentFinished`),
                // which coalesces across the chained turns and fires once.
                completedCleanly = true
            } catch is CancellationError {
                self?.statusText = "Cancelled"
                // A cancelled turn must consume the arm so it doesn't carry over
                // to a later autonomous turn on this still-open session.
                self?.store?.disarmAgentFinished(id: id)
            } catch {
                self?.hasError = true
                self?.statusText = self?.errorMessage(for: error)
                // A failed turn (transport error / socket death with no
                // `message.complete`) likewise consumes the arm here, since no
                // `.turnEnded` reaches the store to disarm it.
                self?.store?.disarmAgentFinished(id: id)
            }
            self?.isSending = false
            self?.turnStartDate = nil
            self?.store?.markTurnFinished(id: id)
            if completedCleanly {
                self?.drainNextQueuedPrompt(client: client)
            }
        }
    }

    /// Submits the next mid-turn-queued prompt (if any) as a real LLM turn after
    /// the current one ended cleanly. Drains one at a time — each turn's clean
    /// completion pulls the next — so a backlog runs FIFO without overlapping.
    /// The drained text is echoed as a user bubble (it becomes a real user turn).
    private func drainNextQueuedPrompt(client: any ChatBackend) {
        guard !queuedPrompts.isEmpty else {
            return
        }
        let next = queuedPrompts.removeFirst()
        Task { await runPrompt(text: next, client: client, echoUser: true) }
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
        case "background", "bg", "btw":
            // `/bg <prompt>` runs concurrently in a background session via the
            // `prompt.background` RPC — never a foreground turn (returns false).
            await startBackgroundPrompt(text: arg, client: client)

        // B. Informational stubs — capabilities Talaria doesn't have, intercepted
        // so they neither hit the LLM nor create confusing harness state.
        case "yolo":
            append(kind: .event, text: "Approval bypass isn't available in Talaria — approvals are interactive here.")
        case "profile":
            append(kind: .event, text: "This window is bound to a single Hermes profile. Open a new window to use another profile.")
        case "skin":
            append(kind: .event, text: "Talaria follows the system appearance; skins aren't supported.")
        case "branch", "fork":
            // Forks the current history into a new live session and opens it.
            await branchCurrentSession(name: arg, client: client)
        case "handoff":
            // Hands the session off to a messaging platform (Slack/Matrix/…) via a
            // request→poll→fail protocol. Only works with a configured `hermes
            // gateway`; otherwise the request RPC returns a clear error.
            await runHandoff(platform: arg, client: client)

        // C. Everything else → harness.
        default:
            return await runHarnessSlash(name: name, arg: arg, client: client)
        }
        return false
    }

    /// Dispatches a `/bg` prompt via `prompt.background` and registers it in
    /// ``backgroundTasks`` for the live indicator. Shared by the idle (`runSlash`)
    /// and mid-turn (`sendWhileBusy`) paths; never starts or touches a foreground
    /// turn, so a live turn keeps streaming alongside it.
    private func startBackgroundPrompt(text: String, client: any ChatBackend) async {
        guard !text.isEmpty else {
            append(kind: .event, text: "Usage: /bg <prompt>")
            return
        }
        do {
            let taskId = try await client.promptBackground(sessionId: sessionId, text: text)
            backgroundTasks.append(BackgroundTask(id: taskId, text: text, state: .running))
            append(kind: .event, text: "🌘 Background task started…")
        } catch {
            append(kind: .event, text: errorMessage(for: error))
        }
    }

    /// Forks the current session via `session.branch`, then opens the new branch
    /// (the store resolves the freshly-created row and switches to it). Surfaces
    /// the harness 4008 "nothing to branch" error for an empty session. `name` is
    /// an optional branch title.
    private func branchCurrentSession(name: String, client: any ChatBackend) async {
        do {
            let result = try await client.branchSession(sessionId: sessionId, name: name.isEmpty ? nil : name)
            append(kind: .event, text: "🌱 Branched into “\(result.title)”.")
            await store?.openBranchedSession(title: result.title)
        } catch {
            append(kind: .event, text: errorMessage(for: error))
        }
    }

    /// Bounded `/handoff` poll: `handoffPollAttempts` attempts spaced by
    /// `handoffPollInterval` (≈30 × 1s, matching the desktop). Instance-level and
    /// observation-ignored so a test can shrink them without racing shared state.
    @ObservationIgnored var handoffPollAttempts = 30
    @ObservationIgnored var handoffPollInterval: Duration = .seconds(1)

    /// Drives a `/handoff <platform>`: request → bounded poll on `handoff.state`
    /// → terminal line. On timeout it marks the handoff failed (so the user can
    /// retry) and says so. Each failure code surfaces the gateway's own message.
    /// Idle-only — `handoff` isn't in the mid-turn sets, so the busy path never
    /// dispatches it.
    private func runHandoff(platform rawPlatform: String, client: any ChatBackend) async {
        let platform = rawPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !platform.isEmpty else {
            append(kind: .event, text: "Usage: /handoff <platform> (e.g. /handoff slack)")
            return
        }
        do {
            let request = try await client.requestHandoff(sessionId: sessionId, platform: platform)
            let destination = request.homeName.isEmpty ? platform : request.homeName
            append(kind: .event, text: "Handing off to \(destination)…")
            // Poll for the terminal state *detached* — crucially NOT while holding
            // the turn-busy state. The poll can run ~30s; if it held `isSending`,
            // anything the user typed meanwhile would be routed to `queuedPrompts`
            // and stranded there (the queue only drains on a clean `runPrompt`,
            // which a handoff never runs). Detaching keeps the session idle and
            // usable while the transfer settles.
            handoffPollTask?.cancel()
            handoffPollTask = Task { [weak self] in
                await self?.pollHandoff(platform: platform, destination: destination, client: client)
            }
        } catch {
            append(kind: .event, text: errorMessage(for: error))
        }
    }

    /// The bounded `handoff.state` poll, run as a detached task by ``runHandoff``.
    /// Appends the terminal line, or on timeout marks the handoff failed (so the
    /// user can retry) and says so. Stops quietly if cancelled (session torn down
    /// or a newer handoff superseded it).
    private func pollHandoff(platform: String, destination: String, client: any ChatBackend) async {
        do {
            for _ in 0 ..< handoffPollAttempts {
                try await Task.sleep(for: handoffPollInterval)
                let state = try await client.handoffState(sessionId: sessionId)
                switch state.state {
                case "completed":
                    append(kind: .event, text: "✓ Handed off to \(destination).")
                    return
                case "failed":
                    let detail = state.error.isEmpty ? "" : ": \(state.error)"
                    append(kind: .event, text: "✗ Handoff failed\(detail).")
                    return
                default:
                    continue // pending / running / "" — keep polling
                }
            }
            // Timed out: mark it failed so a retry is possible, then say so.
            try? await client.failHandoff(sessionId: sessionId, error: "timed out waiting for handoff")
            append(kind: .event, text: "Handoff timed out — retry with /handoff \(platform).")
        } catch is CancellationError {
            // Superseded or shutting down — leave the transcript as-is.
        } catch {
            append(kind: .event, text: errorMessage(for: error))
        }
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
                    // A pending-input dispatch resolved to `send` mid-turn — the
                    // shape Hermes returns for `/queue`, `/q`, the `/steer`
                    // no-active-run fallback, and `/goal <text>`. It must never
                    // start a turn over the live one; instead hold the message and
                    // submit it when the current turn ends cleanly (see
                    // `drainNextQueuedPrompt`). The caller already surfaced the
                    // "Queued." feedback; append any harness notice too.
                    if let notice, !notice.isEmpty {
                        append(kind: .event, text: notice)
                    }
                    queuedPrompts.append(message)
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
        handoffPollTask?.cancel()
        handoffPollTask = nil
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
        case .turnStarted, .turnEnded:
            // Turn-boundary control signals: consumed by the store's always-on
            // observer (notification coalescing). The chat view's busy/turn state
            // is driven by the in-flight prompt, so they're a no-op here.
            break
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
        case let .backgroundComplete(taskId, text):
            // Flip the live indicator's task to finished and render the result.
            // Deliberately does NOT reset the streaming cursor: `/bg` runs
            // concurrently with the foreground turn, so this event can land while
            // the agent reply/thought is mid-stream — nilling the cursor would
            // split that in-progress bubble in two. `append` creates its own
            // event message regardless of the cursor.
            if let index = backgroundTasks.firstIndex(where: { $0.id == taskId }) {
                backgroundTasks[index].state = .finished
            }
            append(kind: .event, text: "🌖 Background task finished:\n\(text)")
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
    private func append(
        kind: ChatTranscriptMessage.Kind,
        text: String,
        images: [Data] = [],
        toolCallId: ToolCallId? = nil
    ) -> UUID? {
        guard !text.isEmpty || !images.isEmpty else {
            return nil
        }
        let message = ChatTranscriptMessage(kind: kind, text: text, images: images, toolCallId: toolCallId)
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
