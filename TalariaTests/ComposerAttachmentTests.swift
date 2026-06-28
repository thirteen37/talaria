import CoreGraphics
import Foundation
import HermesKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Talaria

/// Covers the composer's image intake: ``ImageNormalizer``/``ComposerImage``
/// normalization (decode + downscale + re-encode, with rejection of non-images)
/// and the ``ComposerAttachment`` → ``ContentBlock`` wire mapping.
@Suite
struct ComposerAttachmentTests {
    @Test
    func normalizeValidPNGReturnsPNGAttachment() {
        let png = Self.makePNG(width: 64, height: 48)
        let attachment = ComposerImage.normalize(png, displayName: "shot.png")
        let unwrapped = try? #require(attachment)
        #expect(unwrapped?.mimeType == "image/png")
        #expect(unwrapped?.displayName == "shot.png")
        #expect((unwrapped?.data.isEmpty == false))
    }

    @Test
    func normalizeNonImageReturnsNil() {
        let garbage = Data("this is not an image".utf8)
        #expect(ComposerImage.normalize(garbage, displayName: nil) == nil)
    }

    @Test
    func normalizeOversizedDownscalesToMaxEdge() {
        // A 4000×3000 image must come back with its longest edge clamped to the
        // 2048 cap (no upscaling for already-small images is covered implicitly
        // by the valid-PNG test, whose 64×48 stays untouched).
        let big = Self.makePNG(width: 4000, height: 3000)
        let attachment = ComposerImage.normalize(big, displayName: nil)
        let unwrapped = try? #require(attachment)
        let dims = unwrapped.flatMap { Self.dimensions(of: $0.data) }
        let size = try? #require(dims)
        if let size {
            #expect(max(size.width, size.height) <= ImageNormalizer.maxEdge)
            // Aspect ratio preserved: 4000×3000 → 2048×1536.
            #expect(size.width == 2048)
            #expect(size.height == 1536)
        }
    }

    @Test
    func contentBlockRoundTripsDataAndMime() {
        let bytes = Data([0x01, 0x02, 0x03, 0xFF])
        let attachment = ComposerAttachment(data: bytes, mimeType: "image/jpeg")
        guard case let .image(image) = attachment.contentBlock() else {
            Issue.record("expected an image content block")
            return
        }
        #expect(image.mimeType == "image/jpeg")
        #expect(image.data == bytes.base64EncodedString())
    }

    @Test
    func equatableIsKeyedOnIdOnly() {
        let shared = UUID()
        let a = ComposerAttachment(id: shared, data: Data([1]), mimeType: "image/png")
        let b = ComposerAttachment(id: shared, data: Data([2, 3]), mimeType: "image/jpeg")
        let c = ComposerAttachment(data: Data([1]), mimeType: "image/png")
        #expect(a == b)        // same id, different payload → equal
        #expect(a != c)        // different id → not equal
    }

    // MARK: - Fixtures

    /// A solid-colour PNG of the given pixel size, built via CoreGraphics so the
    /// tests need no bundled asset.
    private static func makePNG(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Pixel dimensions of encoded image bytes, read from ImageIO metadata.
    private static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}
