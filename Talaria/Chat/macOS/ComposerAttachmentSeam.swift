import AppKit
import SwiftUI
import UniformTypeIdentifiers

// macOS half of the composer attachment seam. The iOS half lives in
// `Chat/iOS/ComposerAttachmentSeam.swift` and defines the same symbols; the
// `**/iOS/**` / `**/macOS/**` folder excludes in `project.yml` compile only
// one half per target, so neither needs `#if`.

/// Attach-images button for the composer (macOS half): opens the existing
/// `NSOpenPanel`-backed image picker. There is no visible paste button here —
/// ⌘V is handled by ``composerImagePaste(onPaste:)``, a local key-event
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
    func composerImagePaste(onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) -> some View {
        background(ComposerPasteMonitor(onPaste: onPaste))
    }
}

/// `NSViewRepresentable` host for ``ComposerPasteMonitor/MonitorHostView``,
/// which owns the actual key-event monitor for the lifetime of its window
/// attachment.
private struct ComposerPasteMonitor: NSViewRepresentable {
    let onPaste: @MainActor ([ComposerAttachment]) -> Void

    func makeNSView(context: Context) -> MonitorHostView {
        MonitorHostView(onPaste: onPaste)
    }

    func updateNSView(_ nsView: MonitorHostView, context: Context) {
        nsView.onPaste = onPaste
    }

    /// Zero-size `NSView` whose only job is installing/removing the ⌘V
    /// monitor for the lifetime of its window attachment.
    final class MonitorHostView: NSView {
        var onPaste: @MainActor ([ComposerAttachment]) -> Void
        private var monitor: Any?

        init(onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) {
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
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
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
