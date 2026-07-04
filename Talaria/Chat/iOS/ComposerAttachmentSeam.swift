import SwiftUI
import UIKit
import UniformTypeIdentifiers

// iOS half of the composer attachment seam. The macOS half lives in
// `Chat/macOS/ComposerAttachmentSeam.swift` and defines the same symbols; the
// `**/iOS/**` / `**/macOS/**` folder excludes in `project.yml` compile only
// one half per target, so neither needs `#if`.
//
// Additive for now: `composerPasteControl` in `Platform/iOS/PlatformSeam.swift`
// still exists and is still wired into `Composer.swift`. A later task switches
// `Composer.swift` over to these new symbols and removes the old one.

/// Attach-images control for the composer (iOS half): a single `Menu` (rather
/// than macOS's single button) because iOS fans intake out over four sources —
/// Photos, Camera, Files, and the general pasteboard — each needing its own
/// picker state. Rows that need hardware/content availability (Camera,
/// Clipboard) hide themselves rather than showing disabled.
struct ComposerAttachmentButton: View {
    let onAttach: @MainActor ([ComposerAttachment]) -> Void

    @State private var isPickingPhotos = false
    @State private var isPickingFiles = false
    @State private var isPresentingCamera = false

    var body: some View {
        Menu {
            Button {
                isPickingPhotos = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    isPresentingCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            Button {
                isPickingFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            if UIPasteboard.general.hasImages {
                Button {
                    loadComposerAttachments(from: UIPasteboard.general.itemProviders) { onAttach([$0]) }
                } label: {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Label("Attach", systemImage: "plus")
        }
        .labelStyle(.iconOnly)
        .help("Attach")
        .accessibilityLabel("Attach")
        .imagePicker(isPresented: $isPickingPhotos) { onAttach($0) }
        .imageFileImporter(isPresented: $isPickingFiles) { onAttach($0) }
        .cameraPicker(isPresented: $isPresentingCamera) { onAttach($0) }
    }
}

extension View {
    /// No-op on iOS — there is no ⌘V text-field paste path here; the explicit
    /// Clipboard row in ``ComposerAttachmentButton``'s menu covers pasting
    /// instead, matching the platform convention of an in-menu action rather
    /// than a keyboard shortcut most iOS devices can't invoke anyway.
    func composerImagePaste(onPaste: @escaping @MainActor ([ComposerAttachment]) -> Void) -> some View {
        self
    }

    /// Files row backing: a multi-select `.fileImporter` scoped to images.
    /// Picked URLs need security-scoped resource access to read outside the
    /// app sandbox; each file's bytes are normalized off the main actor before
    /// delivery, mirroring macOS's `imagePicker`.
    func imageFileImporter(
        isPresented: Binding<Bool>,
        onPick: @escaping @MainActor ([ComposerAttachment]) -> Void
    ) -> some View {
        fileImporter(
            isPresented: isPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            Task.detached {
                let attachments = urls.compactMap { url -> ComposerAttachment? in
                    guard url.startAccessingSecurityScopedResource() else { return nil }
                    defer { url.stopAccessingSecurityScopedResource() }
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return ComposerImage.normalize(data, displayName: url.lastPathComponent)
                }
                await onPick(attachments)
            }
        }
    }

    /// Camera row backing: presents ``CameraPicker`` full-screen when
    /// `isPresented` flips true.
    func cameraPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping @MainActor ([ComposerAttachment]) -> Void
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CameraPicker(onPick: onPick)
                .ignoresSafeArea()
        }
    }
}

/// `UIImagePickerController` wrapper for capturing a photo with the device
/// camera. The captured image is JPEG-encoded, normalized off the main actor
/// (mirroring every other intake path's decode/downscale/re-encode), then
/// delivered via `onPick` before the cover dismisses itself.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: @MainActor ([ComposerAttachment]) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: @MainActor ([ComposerAttachment]) -> Void
        let dismiss: DismissAction

        init(onPick: @escaping @MainActor ([ComposerAttachment]) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            dismiss()
            guard let image = info[.originalImage] as? UIImage,
                  let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
            let onPick = onPick
            Task.detached {
                guard let attachment = ComposerImage.normalize(jpeg, displayName: nil) else { return }
                await onPick([attachment])
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
