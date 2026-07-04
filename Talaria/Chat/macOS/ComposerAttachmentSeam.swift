import AppKit
import SwiftUI
import UniformTypeIdentifiers

// macOS half of the composer attachment seam. The iOS half lives in
// `Chat/iOS/ComposerAttachmentSeam.swift` and defines the same symbols; the
// `**/iOS/**` / `**/macOS/**` folder excludes in `project.yml` compile only
// one half per target, so neither needs `#if`.

/// Attach-images button for the composer (macOS half): opens the existing
/// `NSOpenPanel`-backed image picker. There is no visible paste button here —
/// ⌘V is handled by ``composerImagePaste(isComposerFocused:onPaste:)``, a local key-event
/// monitor attached to the composer body's background, matching the platform
/// convention of pasting in place rather than via a dedicated control.
struct ComposerAttachmentButton: View {
    let onAttach: @MainActor ([ComposerAttachment]) -> Void
    @State private var isPickingImages = false

    var body: some View {
        Button {
            isPickingImages = true
        } label: {
            Image(systemName: "photo.on.rectangle")
        }
        .help("Attach images")
        .accessibilityLabel("Attach images")
        .imagePicker(isPresented: $isPickingImages) { onAttach($0) }
    }
}

extension View {
    /// Wires ⌘V image paste for the composer. Implemented as a local
    /// `NSEvent` key-down monitor — installed ahead of AppKit's normal
    /// responder-chain dispatch — rather than `.onPasteCommand`, because the
    /// composer's `TextField` field editor (`NSTextView`) unconditionally
    /// claims `paste:` once it holds first responder (the normal case while
    /// composing), which would otherwise swallow ⌘V before an ancestor's
    /// `.onPasteCommand` ever saw it. When the general pasteboard holds image
    /// data, the monitor delivers it and consumes the event; otherwise (no
    /// image, or a different key) it returns the event unchanged so normal
    /// text paste into the focused field is untouched. Scoped to this view's
    /// own window (via `event.window` equality) so multiple open windows,
    /// each with their own composer/monitor, never cross-fire into one
    /// another.
    ///
    /// Being scoped to the window isn't enough on its own, though: any ⌘V
    /// pressed anywhere in that window — including while an unrelated text
    /// field elsewhere in the same window (e.g. a session rename field) has
    /// focus — would otherwise be captured and silently redirected into this
    /// composer instead of the field the user is actually looking at.
    /// `isComposerFocused` (backed by the composer's own `@FocusState`) lets
    /// the monitor tell "our field editor has focus" apart from "some other
    /// text-editing control in the same window has focus": it gates on
    /// `isComposerFocused() || !(hostWindow.firstResponder is NSText)`. The
    /// second half alone would be wrong — the composer's own `TextField`
    /// field editor is itself an `NSTextView`, which conforms to `NSText`, so
    /// a bare "first responder isn't `NSText`" check can't distinguish "our
    /// field" from "someone else's field" and would regress the very case
    /// this monitor exists to fix. The combined OR correctly intercepts when
    /// the composer itself is focused (regardless of what `firstResponder`
    /// literally is) or when nothing/a non-text control has focus (safe
    /// default), while leaving any *other* focused text field's normal
    /// paste: behavior alone.
    func composerImagePaste(
        isComposerFocused: @escaping () -> Bool,
        onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void
    ) -> some View {
        background(ComposerPasteMonitor(isComposerFocused: isComposerFocused, onPaste: onPaste))
    }
}

/// `NSViewRepresentable` host for ``ComposerPasteMonitor/MonitorHostView``,
/// which owns the actual key-event monitor for the lifetime of its window
/// attachment.
private struct ComposerPasteMonitor: NSViewRepresentable {
    let isComposerFocused: () -> Bool
    let onPaste: @MainActor ([ComposerAttachment]) -> Void

    func makeNSView(context: Context) -> MonitorHostView {
        MonitorHostView(isComposerFocused: isComposerFocused, onPaste: onPaste)
    }

    func updateNSView(_ nsView: MonitorHostView, context: Context) {
        nsView.isComposerFocused = isComposerFocused
        nsView.onPaste = onPaste
    }

    /// Zero-size `NSView` whose only job is installing/removing the ⌘V
    /// monitor for the lifetime of its window attachment.
    final class MonitorHostView: NSView {
        var isComposerFocused: () -> Bool
        var onPaste: @MainActor ([ComposerAttachment]) -> Void
        private var monitor: Any?

        init(isComposerFocused: @escaping () -> Bool, onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) {
            self.isComposerFocused = isComposerFocused
            self.onPaste = onPaste
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard let hostWindow = window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak hostWindow] event in
                guard let self, let hostWindow, event.window === hostWindow else { return event }
                // Mask only the intent modifiers, not the full
                // deviceIndependentFlagsMask — that mask also includes
                // .capsLock, so leaving Caps Lock on would otherwise make
                // this guard fail (intersection becomes [.command, .capsLock])
                // and silently drop the image paste.
                guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                // Only handle this ⌘V if it's "ours": either the composer's
                // own field editor currently has focus, or nothing/a
                // non-text control does. If some *other* text-editing
                // control in this window is focused (e.g. a session rename
                // field), leave the event alone so that control's own paste:
                // behavior runs instead of hijacking it into this composer.
                guard self.isComposerFocused() || !(hostWindow.firstResponder is NSText) else { return event }
                let datas = Self.pasteboardImageData()
                guard !datas.isEmpty else { return event }
                let onPaste = self.onPaste
                Task.detached {
                    let attachments = datas.compactMap { ComposerImage.normalize($0, displayName: nil) }
                    await onPaste(attachments)
                }
                return nil
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Raw image bytes on the general pasteboard, read on the main actor
        /// (same shape as the pre-attachment-seam `pasteboardImageData()`
        /// this supersedes). Reads real pasteboard data — unlike
        /// ``ComposerImage/pasteboardHasImage``'s cheap type-only check —
        /// but only in direct response to an actual user-initiated ⌘V.
        @MainActor
        private static func pasteboardImageData() -> [Data] {
            let pasteboard = NSPasteboard.general
            for type in pasteboard.types ?? [] {
                guard let utType = UTType(type.rawValue), utType.conforms(to: .image),
                      let data = pasteboard.data(forType: type) else { continue }
                return [data]
            }
            guard let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] else {
                return []
            }
            return images.compactMap { $0.tiffRepresentation }
        }
    }
}
