import HermesKit
import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    @Binding var prompt: String
    /// Images staged for the next turn, shown as a removable thumbnail strip.
    @Binding var attachments: [ComposerAttachment]
    var isSending: Bool
    var isBlocked: Bool
    /// Placeholder shown while `isBlocked` — varies by the pending prompt kind
    /// (permission / question / secret) so it matches the status line.
    var blockedPlaceholder: String = "Waiting for permission"
    var availableCommands: [AvailableCommand]
    var send: () -> Void
    var cancel: () -> Void
    /// Page Up / Page Down forwarded to the transcript scroller (`ChatView` sets
    /// `pendingScroll`). The window-wide `ChatView.chatShortcuts` layer covers
    /// paging when focus is *outside* the composer; these own it while the field
    /// holds focus, where a focused multi-line editor can otherwise swallow the
    /// page keys before a modifier-less window-wide shortcut fires. The two paths
    /// are made mutually exclusive via `onFocusChange` (ChatView disables its
    /// window-wide page shortcuts while focused), so they can't both fire for one
    /// press regardless of AppKit routing order. Defaulted to no-ops so previews /
    /// other call sites keep compiling.
    var onPageUp: () -> Void = {}
    var onPageDown: () -> Void = {}
    /// Reports composer focus changes up to `ChatView` so it can gate its
    /// window-wide Page Up/Down shortcuts on the composer *not* being focused —
    /// the structural guarantee that the composer and window-wide page paths never
    /// both handle the same keypress.
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Drives ⌘L focus-the-composer from anywhere in the window.
    @FocusState private var inputFocused: Bool
    @State private var isSlashMenuDismissed = false
    @State private var slashMenuHeight: CGFloat = 0
    @State private var selectedCommandIndex = 0
    /// Drives the platform image picker (`NSOpenPanel` / `PhotosPicker`).
    @State private var isPickingImages = false
    /// Highlights the composer while an image drag hovers over it.
    @State private var isDropTargeted = false
    /// First Esc over a live turn arms the cancel (a hint appears); the second
    /// confirms. Guards against a stray Esc dropping a running turn or a
    /// half-typed message. Cleared by typing, when the turn ends, or after a
    /// short window so a much-later Esc doesn't act on a stale arm.
    @State private var escapeArmedToCancel = false

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty-field placeholder. While blocked it mirrors the pending prompt's
    /// status copy; otherwise it advertises the ⌘L focus shortcut — but only where
    /// a hardware keyboard is guaranteed (`showsKeyboardShortcutHints`), so iOS
    /// without a keyboard doesn't promise an unreachable chord.
    private var placeholder: String {
        if isBlocked { return blockedPlaceholder }
        return Platform.showsKeyboardShortcutHints ? "Message Hermes (⌘L)" : "Message Hermes"
    }

    private var matchingCommands: [AvailableCommand] {
        guard prompt.hasPrefix("/") else {
            return []
        }

        let query = String(prompt.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ranked = rankedSlashCommands(availableCommands, matching: query)
        // While a turn is in flight only the gateway's pending-input commands and
        // the concurrent background commands can be dispatched, so the menu offers
        // just those — matching what `LocalChatViewModel.sendWhileBusy` accepts.
        guard isSending else {
            return ranked
        }
        return ranked.filter {
            let name = $0.name.lowercased()
            return SlashCommand.pendingInputCommands.contains(name)
                || SlashCommand.backgroundCommands.contains(name)
        }
    }

    /// Whether the current composer text can actually be dispatched over a live
    /// turn: plain text (auto-queued) or a pending-input slash. A non-pending
    /// slash (`/help`, `/model`, …) can't — the slash menu already hides those
    /// while busy, and `LocalChatViewModel.sendWhileBusy` no-ops on them — so the
    /// Send button is disabled to match rather than imply an action that never runs.
    private var canSendWhileBusy: Bool {
        let trimmed = trimmedPrompt
        guard trimmed.hasPrefix("/") else {
            return true
        }
        let parsed = SlashCommand(parsing: trimmed)
        return parsed.isPendingInput || parsed.isBackground
    }

    /// Help text for the Send button while a turn is in flight — adapts to what
    /// the current composer text will do (queue / steer / generic send), and
    /// explains the disabled state for a non-pending slash.
    private var busySendHelp: String {
        let trimmed = trimmedPrompt
        guard trimmed.hasPrefix("/") else {
            return "Queue this message"
        }
        let parsed = SlashCommand(parsing: trimmed)
        switch parsed.name.lowercased() {
        case "queue", "q": return "Queue this message"
        case "steer": return "Steer the running turn"
        case "background", "bg", "btw": return "Run this prompt in the background"
        default:
            return parsed.isPendingInput
                ? "Send while running"
                : "This command can't be sent until the turn finishes"
        }
    }

    private var visibleCommands: [AvailableCommand] {
        isSlashMenuDismissed ? [] : matchingCommands
    }

    /// The currently highlighted command, falling back to the first row if the
    /// tracked index has drifted out of bounds (defensive; the index is reset to
    /// 0 on every re-filter, which is always valid for a non-empty list).
    private var selectedCommand: AvailableCommand? {
        let commands = visibleCommands
        guard !commands.isEmpty else { return nil }
        return commands.indices.contains(selectedCommandIndex)
            ? commands[selectedCommandIndex]
            : commands.first
    }

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                attachmentStrip
            }
            inputRow
        }
        .padding(12)
        // Highlight the composer while an image drag hovers over it.
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Attach via the platform picker (NSOpenPanel / PhotosPicker).
        .imagePicker(isPresented: $isPickingImages) { addAttachments($0) }
        // Drag-and-drop images onto the composer (both platforms).
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            loadComposerAttachments(from: providers) { addAttachment($0) }
            return true
        }
    }

    /// The text input row plus its leading attach/paste controls, send/cancel
    /// buttons, slash-command menu, and the hidden ⌘L focus shortcut.
    private var inputRow: some View {
        HStack(spacing: 8) {
            if !isBlocked {
                composerPasteControl { addAttachments($0) }

                Button { isPickingImages = true } label: {
                    Image(systemName: "photo.on.rectangle")
                }
                .help("Attach images")
                .accessibilityLabel("Attach images")
            }

            TextField(placeholder, text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .disabled(isBlocked)
                .focused($inputFocused)
                .onChange(of: prompt) { _, newValue in
                    if !newValue.hasPrefix("/") {
                        isSlashMenuDismissed = false
                    }
                    // Each keystroke re-filters the list; reset the highlight to
                    // the top (index 0 is always valid for a non-empty list).
                    selectedCommandIndex = 0
                    // Editing the message disarms a pending Esc-cancel.
                    escapeArmedToCancel = false
                }
                .onChange(of: isSending) { _, busy in
                    // A turn ending (or being cancelled) disarms any pending Esc-cancel.
                    if !busy { escapeArmedToCancel = false }
                }
                .onChange(of: inputFocused) { _, focused in
                    // Report focus up so ChatView disables its window-wide page
                    // shortcuts while we own the keys (see `onPageUp`/`onPageDown`).
                    onFocusChange(focused)
                }
                .task(id: escapeArmedToCancel) {
                    // Auto-disarm after a short window so the cancel reads as a
                    // double-tap, not a latent state a much-later Esc can trip.
                    guard escapeArmedToCancel else { return }
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    escapeArmedToCancel = false
                }
                .onKeyPress(.upArrow, phases: .down) { _ in
                    let count = visibleCommands.count
                    guard count > 0 else { return .ignored }
                    selectedCommandIndex = (selectedCommandIndex - 1 + count) % count
                    return .handled
                }
                .onKeyPress(.downArrow, phases: .down) { _ in
                    let count = visibleCommands.count
                    guard count > 0 else { return .ignored }
                    selectedCommandIndex = (selectedCommandIndex + 1) % count
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    if let command = selectedCommand {
                        accept(command)
                        return .handled
                    }
                    send()
                    return .handled
                }
                .onKeyPress(.tab, phases: .down) { _ in
                    guard let command = selectedCommand else {
                        return .ignored
                    }
                    accept(command)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    // Esc dismisses the slash menu first; only when no menu is
                    // open does it act on a live turn. Interrupting takes a
                    // *double* Esc — the first press arms the cancel (and shows a
                    // hint), the second confirms — so a stray Esc never drops a
                    // running turn or a half-typed message. ⌘. still cancels in
                    // one chord.
                    if !visibleCommands.isEmpty {
                        isSlashMenuDismissed = true
                        return .handled
                    }
                    guard isSending else {
                        return .ignored
                    }
                    if escapeArmedToCancel {
                        escapeArmedToCancel = false
                        cancel()
                    } else {
                        escapeArmedToCancel = true
                    }
                    return .handled
                }
                .onKeyPress(KeyEquivalent("."), phases: .down) { press in
                    // ⌘. interrupts the running turn without leaving the text
                    // field — the macOS-conventional cancel chord.
                    guard isSending, press.modifiers.contains(.command) else {
                        return .ignored
                    }
                    cancel()
                    return .handled
                }
                .onKeyPress(.pageUp) {
                    // Page the transcript while the composer keeps focus.
                    // `.handled` overrides the field's own page-scroll. The
                    // window-wide page shortcut is disabled whenever we're focused
                    // (via `onFocusChange`), so only this path fires here.
                    onPageUp()
                    return .handled
                }
                .onKeyPress(.pageDown) {
                    onPageDown()
                    return .handled
                }

            if isSending {
                // Both controls while busy: Cancel always interrupts; Send
                // queues/steers the running turn when there's text to dispatch.
                Button(action: cancel) {
                    Image(systemName: "stop.fill")
                }
                .help("Interrupt the current turn (⌘. or Esc Esc)")
                .accessibilityLabel("Cancel")

                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .help(busySendHelp)
                .accessibilityLabel("Send")
                .disabled(trimmedPrompt.isEmpty || isBlocked || !canSendWhileBusy)
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .help("Send")
                .accessibilityLabel("Send")
                // Idle: send when there's text *or* a staged image.
                .disabled((trimmedPrompt.isEmpty && attachments.isEmpty) || isBlocked)
            }
        }
        // Hidden, zero-size ⌘L shortcut layer: focuses the composer from anywhere
        // in the window. Mounted as a background (not inside the input `HStack`, so
        // it adds no layout/spacing) — the same hidden-shortcut pattern as
        // `ChatView.permissionShortcuts`. Always present in a live chat, so ⌘L
        // works window-wide; read-only sessions have no composer, so it's absent
        // (a harmless no-op) there.
        .background {
            Button("Focus Composer") { inputFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // Float the slash-command menu above the input row as an overlay so it no
        // longer consumes layout height — the composer's measured height stays
        // constant whether or not the menu shows, so the status bar / transcript
        // above it don't get pushed up. The overlay anchors to the input `HStack`
        // (before the outer `.padding`) so its container top edge is the text box's
        // top edge, then we lift the menu by its own measured height via `.offset`
        // so its bottom edge lands exactly on the top of the text box. (An
        // `.alignmentGuide(.top) { $0[.bottom] }` is unreliable inside `.overlay` —
        // it left the menu sitting on top of the text field — so we measure and
        // offset instead. The opacity gate hides the menu for the single layout
        // pass before its height is known, avoiding a flash at the un-offset spot.)
        .overlay(alignment: .topLeading) {
            if !visibleCommands.isEmpty, !isBlocked {
                SlashMenu(commands: visibleCommands, selectedIndex: selectedCommandIndex) { command in
                    accept(command)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SlashMenuHeightKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(SlashMenuHeightKey.self) { height in
                    if abs(height - slashMenuHeight) > 0.5 {
                        slashMenuHeight = height
                    }
                }
                .offset(y: -slashMenuHeight)
                .opacity(slashMenuHeight > 0 ? 1 : 0)
            }
        }
        // Float the double-Esc hint above the input row (like the slash menu) so
        // it doesn't shift layout. Only shown while a turn is in flight, the
        // cancel is armed, and no slash menu is competing for the same space.
        .overlay(alignment: .topTrailing) {
            if isSending, escapeArmedToCancel, visibleCommands.isEmpty {
                Text("Press Esc again to interrupt")
                    .font(.caption)
                    // Dimmed `.primary`, not `.secondary`: the latter is invisible
                    // over a material on some iOS devices.
                    .foregroundStyle(.primary.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .offset(y: -34)
            }
        }
    }

    /// Horizontal strip of staged-image thumbnails, each with a remove (✕)
    /// affordance. Shown only when at least one image is staged.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumbnail(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accept(_ command: AvailableCommand) {
        prompt = "/\(command.name) "
        isSlashMenuDismissed = true
    }

    /// Append normalized attachments staged from a picker/paste/drop.
    private func addAttachments(_ new: [ComposerAttachment]) {
        guard !new.isEmpty else { return }
        attachments.append(contentsOf: new)
    }

    private func addAttachment(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
    }
}

/// One staged-image tile in the composer's attachment strip: a cached 56×56
/// thumbnail (decoded once via ``CachedThumbnail``, keyed on the attachment id)
/// with a remove (✕) overlay.
private struct AttachmentThumbnail: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CachedThumbnail(data: attachment.data, id: attachment.id, size: 56, cornerRadius: 6)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Remove image")
            .accessibilityLabel("Remove image")
        }
    }
}

private struct SlashMenuHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Match quality of `query` against a command `name`, lower = better.
/// Returns nil when the name does not contain the query at all.
/// Both arguments are expected lowercased.
func slashCommandMatchTier(name: String, query: String) -> Int? {
    if name == query { return 0 }
    if name.hasPrefix(query) { return 1 }
    guard let range = name.range(of: query) else { return nil }
    let before = name[name.index(before: range.lowerBound)]
    return "-_:./ ".contains(before) ? 2 : 3
}

/// Filter `commands` to those whose name matches `query` (case-insensitive
/// substring) and order them by match quality (exact > prefix > word-boundary
/// > interior). Ties preserve original server order. `query` should already be
/// lowercased and trimmed; an empty query returns `commands` unchanged.
func rankedSlashCommands(_ commands: [AvailableCommand], matching query: String) -> [AvailableCommand] {
    guard !query.isEmpty else { return commands }
    return commands.enumerated()
        .compactMap { index, command -> (tier: Int, index: Int, command: AvailableCommand)? in
            guard let tier = slashCommandMatchTier(name: command.name.lowercased(), query: query)
            else { return nil }
            return (tier, index, command)
        }
        .sorted { $0.tier != $1.tier ? $0.tier < $1.tier : $0.index < $1.index }
        .map(\.command)
}
