import SwiftUI

// macOS half of the composer attachment seam. The iOS half lives in
// `Chat/iOS/ComposerAttachmentSeam.swift` and defines the same symbols; the
// `**/iOS/**` / `**/macOS/**` folder excludes in `project.yml` compile only
// one half per target, so neither needs `#if`.

/// Attach-images button for the composer (macOS half): opens the existing
/// `NSOpenPanel`-backed image picker. There is no visible paste button here —
/// ⌘V is handled by ``composerImagePaste(onPaste:)`` directly on the text
/// field, matching the platform convention of pasting in place rather than
/// via a dedicated control.
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
    /// Wires ⌘V image paste directly to this view (typically the composer's
    /// text field) via `onPasteCommand`, so pasting an image doesn't require a
    /// visible button. Delivers each loaded provider as its own single-element
    /// batch, mirroring ``loadComposerAttachments(from:onEach:)``'s
    /// per-item delivery.
    func composerImagePaste(onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) -> some View {
        onPasteCommand(of: [.image]) { providers in
            loadComposerAttachments(from: providers) { onPaste([$0]) }
        }
    }
}
