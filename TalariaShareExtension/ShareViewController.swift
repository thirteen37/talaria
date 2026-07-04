import HermesSharing
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Principal class for the "incoming share" extension (`NSExtensionPrincipalClass`
/// in Info.plist). Thin by design: it stages the shared text/images into the App
/// Group container via `PendingShareStore`, then hands off to the host app with a
/// `talaria://share?id=<uuid>` deep link — it does **not** pick a profile/session
/// or send anything. Normalization (downscale/re-encode) is deferred to the host
/// app to stay under the extension's tight memory ceiling; here we stage the
/// *original* bytes only. See docs/architecture.md.
final class ShareViewController: UIViewController {
    private enum ShareError: LocalizedError {
        case nothingToShare
        case providerFailed

        var errorDescription: String? {
            switch self {
            case .nothingToShare: return "Nothing to share."
            case .providerFailed: return "Couldn’t read the shared item."
            }
        }
    }

    private let store = PendingShareStore()
    private let state = ShareStagingState()

    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareStagingView(state: state))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await stageAndHandOff() }
    }

    private func stageAndHandOff() async {
        // Opportunistically GC orphans from shares the user never followed up on
        // (e.g. force-quit before the host-app sheet appeared).
        try? await store.pruneStale()

        do {
            let (text, images) = await extractSharedContent()
            guard text != nil || !images.isEmpty else { throw ShareError.nothingToShare }

            let item = try await store.stage(text: text, images: images)
            state.status = .success
            openHostApp(shareID: item.id)
        } catch {
            state.status = .failed(error.localizedDescription)
            // Give the user a moment to read the failure, then dismiss.
            try? await Task.sleep(for: .seconds(1.5))
            completeRequest()
        }
    }

    // MARK: - Extraction

    private func extractSharedContent() async -> (text: String?, images: [(data: Data, mimeType: String)]) {
        var text: String?
        var images: [(data: Data, mimeType: String)] = []

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                // Image takes precedence — a provider that vends both (rare) is
                // most useful to Talaria as an image attachment.
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let image = await loadImage(from: provider) {
                        images.append(image)
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let loaded = await loadText(from: provider) {
                        text = [text, loaded].compactMap { $0 }.joined(separator: "\n")
                    }
                }
            }
        }
        return (text, images)
    }

    /// Loads a shared image as *original* bytes where possible (data
    /// representation → file URL), re-encoding to PNG only as a last resort.
    private func loadImage(from provider: NSItemProvider) async -> (data: Data, mimeType: String)? {
        // Most specific registered image UTType so we read the real bytes and
        // carry an accurate MIME type (image/heic, image/jpeg, …).
        let imageType = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first { $0.conforms(to: .image) }
        let typeID = imageType?.identifier ?? UTType.image.identifier
        let mime = imageType?.preferredMIMEType ?? "application/octet-stream"

        if let data = try? await loadData(from: provider, typeID: typeID), !data.isEmpty {
            return (data, mime)
        }
        if let fileResult = try? await loadFileData(from: provider, typeID: typeID) {
            return (fileResult.data, fileResult.mime ?? mime)
        }
        if let png = try? await loadUIImagePNG(from: provider) {
            return (png, "image/png")
        }
        return nil
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        if let data = try? await loadData(from: provider, typeID: UTType.plainText.identifier),
           !data.isEmpty {
            let string = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        if let string = try? await loadPlainString(from: provider) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    // MARK: - NSItemProvider continuation wrappers

    private func loadData(from provider: NSItemProvider, typeID: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ShareError.providerFailed)
                }
            }
        }
    }

    private func loadFileData(from provider: NSItemProvider, typeID: String) async throws
        -> (data: Data, mime: String?) {
        try await withCheckedThrowingContinuation { continuation in
            // The URL is only valid inside this closure, so read the bytes here.
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareError.providerFailed)
                    return
                }
                do {
                    let data = try Data(contentsOf: url)
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    continuation.resume(returning: (data, mime))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Object loaders extract a `Sendable` value (`Data`/`String`) *inside* the
    // completion so no non-Sendable class (`UIImage`/`NSString`) crosses the
    // continuation's actor hop — required under Swift 6 strict concurrency.
    private func loadUIImagePNG(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage, let png = image.pngData() {
                    continuation.resume(returning: png)
                } else {
                    continuation.resume(throwing: error ?? ShareError.providerFailed)
                }
            }
        }
    }

    private func loadPlainString(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSString.self) { object, error in
                if let ns = object as? NSString {
                    continuation.resume(returning: ns as String)
                } else {
                    continuation.resume(throwing: error ?? ShareError.providerFailed)
                }
            }
        }
    }

    // MARK: - Hand-off

    private func openHostApp(shareID: UUID) {
        guard let url = URL(string: "talaria://share?id=\(shareID.uuidString)") else {
            completeRequest()
            return
        }
        // Extensions can't touch UIApplication; `extensionContext.open` is the
        // sanctioned hand-off. Complete only *after* the open resolves so the
        // host app is launched/foregrounded before this extension tears down.
        extensionContext?.open(url) { [weak self] _ in
            self?.completeRequest()
        }
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
