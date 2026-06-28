import CoreGraphics
import Foundation
import HermesKit
import ImageIO
import UniformTypeIdentifiers

/// A normalized image staged in the chat composer, ready to send as a
/// ``ContentBlock/image(_:)``. Its bytes are already downscaled and re-encoded
/// by ``ComposerImage/normalize(_:displayName:)``, so `mimeType` is always
/// `image/png` or `image/jpeg`. `Equatable` is keyed on `id` only — the data is
/// large and identity is what the composer's strip tracks for add/remove.
struct ComposerAttachment: Identifiable, Equatable, Sendable {
    let id: UUID
    var data: Data
    var mimeType: String
    var displayName: String?

    init(id: UUID = UUID(), data: Data, mimeType: String, displayName: String? = nil) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.displayName = displayName
    }

    static func == (lhs: ComposerAttachment, rhs: ComposerAttachment) -> Bool {
        lhs.id == rhs.id
    }

    /// The wire content block: base64-encoded normalized bytes + mime type.
    func contentBlock() -> ContentBlock {
        .image(ImageContent(data: data.base64EncodedString(), mimeType: mimeType))
    }
}

/// Cross-platform image normalization shared by both platform seams'
/// ``ComposerImage`` (so the ImageIO downscale/re-encode isn't duplicated). Pure
/// and free of `NSImage`/`UIImage`, so it runs off the main actor; the seam adds
/// only the platform-specific pasteboard read on top.
enum ImageNormalizer {
    /// Longest-edge cap for the downscaled image.
    static let maxEdge = 2048
    /// Hard cap on the encoded byte size; larger inputs that won't compress under
    /// it are rejected (`nil`).
    static let maxBytes = 25 * 1024 * 1024

    /// Decode `raw`, downscale its longest edge to ``maxEdge``, and re-encode as
    /// PNG — falling back to JPEG (q≈0.8) when the PNG exceeds ``maxBytes``.
    /// Returns `nil` for non-image bytes or an image that can't be brought under
    /// the size cap. Honors EXIF orientation so rotated photos render upright.
    static func normalize(_ raw: Data, displayName: String?) -> ComposerAttachment? {
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        if let png = encode(cgImage, type: UTType.png.identifier, quality: nil), png.count <= maxBytes {
            return ComposerAttachment(data: png, mimeType: "image/png", displayName: displayName)
        }
        if let jpeg = encode(cgImage, type: UTType.jpeg.identifier, quality: 0.8), jpeg.count <= maxBytes {
            return ComposerAttachment(data: jpeg, mimeType: "image/jpeg", displayName: displayName)
        }
        return nil
    }

    private static func encode(_ image: CGImage, type: String, quality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Load + normalize image attachments from dropped or pasted `NSItemProvider`s,
/// delivering each result on the main actor as its load finishes. Shared by
/// drag-and-drop (both platforms) and the iOS paste button. Best-effort and
/// order-independent: providers carrying no decodable image are silently
/// skipped. `nonisolated` so it can be kicked off from either a main-actor or a
/// sendable drop/paste closure; only `onEach` runs on the main actor.
func loadComposerAttachments(
    from providers: [NSItemProvider],
    onEach: @escaping @MainActor (ComposerAttachment) -> Void
) {
    for provider in providers {
        let name = provider.suggestedName
        _ = provider.loadDataRepresentation(for: .image) { data, _ in
            guard let data, let attachment = ComposerImage.normalize(data, displayName: name) else { return }
            Task { @MainActor in onEach(attachment) }
        }
    }
}
