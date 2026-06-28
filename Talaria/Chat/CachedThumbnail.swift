import CoreGraphics
import ImageIO
import SwiftUI

/// A square image thumbnail that decodes its bytes **once**, **downsampled to
/// display size**, into `@State` (keyed on a cheap stable `id`). Two wins over a
/// naive `Image(data:)`:
///
/// - No re-decode when a parent re-evaluates its body (the composer on every
///   keystroke, a chat bubble on every streaming token).
/// - The retained bitmap is sized to the tile (≈`size × displayScale` px), not
///   the full normalized image (up to the 2048px cap, ~16 MB decoded) — so an
///   image-heavy chat doesn't keep a full-res bitmap resident per attachment.
///
/// Decoding runs off the main actor. A neutral placeholder shows until it lands.
struct CachedThumbnail<ID: Hashable>: View {
    let data: Data
    /// Stable, cheap identity for the decode (e.g. an attachment UUID). Must not
    /// be the `Data` itself — hashing multi-MB bytes each render defeats the cache.
    let id: ID
    var size: CGFloat
    var cornerRadius: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?

    init(data: Data, id: ID, size: CGFloat, cornerRadius: CGFloat) {
        self.data = data
        self.id = id
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: id) {
            guard image == nil else { return }
            let bytes = data
            let scale = displayScale
            let maxPixel = max(1, Int((size * scale).rounded()))
            image = await Task.detached(priority: .userInitiated) {
                ImageThumbnailDecoder.decode(bytes, maxPixelSize: maxPixel, scale: scale)
            }.value
        }
    }
}

/// Decodes a downsampled thumbnail straight to a `CGImage` (no intermediate
/// full-res `NSImage`/`UIImage`) via ImageIO, then wraps it in a cross-platform
/// `Image`. Pure and `Sendable`-safe, so it runs off the main actor.
enum ImageThumbnailDecoder {
    static func decode(_ data: Data, maxPixelSize: Int, scale: CGFloat) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return Image(decorative: cgImage, scale: scale)
    }
}
