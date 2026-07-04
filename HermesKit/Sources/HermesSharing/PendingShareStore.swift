import Foundation

/// Reads and writes ``PendingShareItem``s in the App Group container shared
/// between `TalariaShareExtension` and the iOS host app. The extension calls
/// `stage`; the host app calls `pendingItem`/`loadImageData`, then `consume`
/// once it has prefilled the composer. Both sides also call `pruneStale` to
/// garbage-collect shares the user never followed up on.
///
/// Not gated to iOS: `containerURL(forSecurityApplicationGroupIdentifier:)` is
/// available on macOS too, and leaving this ungated lets
/// `swift test --package-path HermesKit` exercise it on a Mac host — the macOS
/// app target simply never calls it. See docs/security.md for the App Group
/// threat model.
public actor PendingShareStore {
    public static let appGroupID = "group.io.lyx.Talaria"

    public enum StoreError: Error, Equatable, Sendable {
        case containerUnavailable
        case ioFailed(String)
    }

    private let containerURLProvider: () -> URL?

    /// - Parameter containerURLOverride: Test seam. Outside an entitled
    ///   process (e.g. plain `swift test`), `containerURL(forSecurityApplicationGroupIdentifier:)`
    ///   returns nil, so tests inject a temp directory here instead.
    public init(appGroupID: String = PendingShareStore.appGroupID, containerURLOverride: URL? = nil) {
        if let containerURLOverride {
            self.containerURLProvider = { containerURLOverride }
        } else {
            self.containerURLProvider = {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            }
        }
    }

    /// Stages raw image bytes (unnormalized — see ``PendingShareItem``) and
    /// optional text under a fresh id, returning the manifest that was
    /// written. Called by the Share Extension.
    @discardableResult
    public func stage(text: String?, images: [(data: Data, mimeType: String)]) async throws -> PendingShareItem {
        let root = try pendingSharesRoot()
        let id = UUID()
        let itemDirectory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try createDirectory(at: itemDirectory)

        var imageFiles: [PendingShareImage] = []
        for (index, image) in images.enumerated() {
            let filename = "image-\(index).dat"
            let fileURL = itemDirectory.appendingPathComponent(filename, isDirectory: false)
            do {
                try image.data.write(to: fileURL, options: [.atomic])
            } catch {
                throw StoreError.ioFailed(error.localizedDescription)
            }
            imageFiles.append(PendingShareImage(filename: filename, mimeType: image.mimeType))
        }

        let item = PendingShareItem(id: id, createdAt: Date(), text: text, imageFiles: imageFiles)
        try writeManifest(item, in: itemDirectory)
        return item
    }

    /// Reads a staged item's manifest, or nil if it doesn't exist (already
    /// consumed, pruned, or never staged). Called by the host app.
    public func pendingItem(id: UUID) async throws -> PendingShareItem? {
        let manifestURL = try itemDirectory(for: id).appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try Self.manifestDecoder.decode(PendingShareItem.self, from: data)
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    /// Loads each staged image's raw bytes for `item`. Called by the host app
    /// right before running them through `ImageNormalizer`.
    public func loadImageData(for item: PendingShareItem) async throws -> [(data: Data, mimeType: String)] {
        let directory = try itemDirectory(for: item.id)
        return try item.imageFiles.map { image in
            let fileURL = directory.appendingPathComponent(image.filename, isDirectory: false)
            do {
                let data = try Data(contentsOf: fileURL)
                return (data, image.mimeType)
            } catch {
                throw StoreError.ioFailed(error.localizedDescription)
            }
        }
    }

    /// Deletes a staged item's entire subfolder (manifest + images) in one
    /// call. Called by the host app after a successful composer prefill.
    public func consume(id: UUID) async throws {
        let directory = try itemDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    /// Deletes staged items older than `olderThan` seconds — orphans left by
    /// shares the user never returned to Talaria to finish (e.g. force-quit
    /// before the incoming-share sheet ever appeared). Callable from either
    /// side; the extension runs it opportunistically on every new share.
    public func pruneStale(olderThan: TimeInterval = 24 * 3600) async throws {
        let root = try pendingSharesRoot()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
            )
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for directory in entries {
            guard let staged = stagedDate(for: directory), staged < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Best-available "staged at" timestamp for a share directory: the manifest's
    /// recorded `createdAt` when readable, otherwise the directory's own
    /// filesystem creation/modification date. The fallback is what makes the GC
    /// cover *interrupted* stages — `stage()` writes image files first and the
    /// manifest last, so an extension killed mid-write leaves a manifest-less
    /// directory that the manifest-only path would leak permanently. Returns nil
    /// only when no date can be determined at all, so such a directory is left
    /// intact rather than blindly deleted.
    private func stagedDate(for directory: URL) -> Date? {
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        if let data = try? Data(contentsOf: manifestURL),
           let item = try? Self.manifestDecoder.decode(PendingShareItem.self, from: data) {
            return item.createdAt
        }
        let values = try? directory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    private func pendingSharesRoot() throws -> URL {
        guard let container = containerURLProvider() else {
            throw StoreError.containerUnavailable
        }
        let root = container.appendingPathComponent("PendingShares", isDirectory: true)
        try createDirectory(at: root, excludeFromBackup: true)
        return root
    }

    private func itemDirectory(for id: UUID) throws -> URL {
        try pendingSharesRoot().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func createDirectory(at url: URL, excludeFromBackup: Bool = false) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
        guard excludeFromBackup else { return }
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }

    private func writeManifest(_ item: PendingShareItem, in directory: URL) throws {
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        do {
            let data = try Self.manifestEncoder.encode(item)
            try data.write(to: manifestURL, options: [.atomic])
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    private static let manifestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let manifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
