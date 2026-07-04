import Foundation

/// One image staged alongside a ``PendingShareItem``, as written by the iOS
/// Share Extension. `filename` is relative to the item's own subfolder in the
/// App Group container (resolved by ``PendingShareStore``), not a full path.
public struct PendingShareImage: Codable, Equatable, Sendable {
    public var filename: String
    public var mimeType: String

    public init(filename: String, mimeType: String) {
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// Text/images staged by the Share Extension into the App Group container,
/// awaiting pickup by the host app (`talaria://share?id=<id>`). Deliberately
/// holds raw, unnormalized image bytes — the extension stays thin and defers
/// the `ImageNormalizer` downscale/re-encode pipeline to the host app, which
/// already runs it off the main actor and isn't under the extension's tight
/// memory ceiling. See docs/architecture.md.
public struct PendingShareItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var text: String?
    public var imageFiles: [PendingShareImage]

    public init(id: UUID, createdAt: Date, text: String?, imageFiles: [PendingShareImage]) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.imageFiles = imageFiles
    }
}
