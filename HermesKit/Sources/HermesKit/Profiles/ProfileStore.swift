import Foundation

public actor ProfileStore {
    public enum StoreError: Error, Equatable, Sendable {
        case notFound(UUID)
        case ioFailed(String)
    }

    public static let defaultDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Talaria", isDirectory: true)
    }()

    public static let defaultURL: URL = defaultDirectory.appendingPathComponent("profiles.json", isDirectory: false)

    private let url: URL
    private let directory: URL
    private var profiles: [ServerProfile] = []
    private var loaded = false

    public init(url: URL = ProfileStore.defaultURL) {
        self.url = url
        self.directory = url.deletingLastPathComponent()
    }

    public func load() async throws -> [ServerProfile] {
        try ensureDirectory()
        guard FileManager.default.fileExists(atPath: url.path) else {
            profiles = []
            loaded = true
            return profiles
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            profiles = try decoder.decode([ServerProfile].self, from: data)
            loaded = true
            return profiles
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    public func all() async throws -> [ServerProfile] {
        try await loadIfNeeded()
        return profiles
    }

    @discardableResult
    public func upsert(_ profile: ServerProfile) async throws -> ServerProfile {
        try await loadIfNeeded()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
        return profile
    }

    public func delete(id: UUID) async throws {
        try await loadIfNeeded()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        profiles.remove(at: idx)
        try persist()
    }

    @discardableResult
    public func duplicate(id: UUID) async throws -> ServerProfile {
        try await loadIfNeeded()
        guard let source = profiles.first(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        var copy = source
        copy.id = UUID()
        copy.name = nextCopyName(of: source.name)
        copy.version = nil
        profiles.append(copy)
        try persist()
        return copy
    }

    private func loadIfNeeded() async throws {
        if !loaded {
            _ = try await load()
        }
    }

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    private func persist() throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.ioFailed(error.localizedDescription)
        }
    }

    private func nextCopyName(of base: String) -> String {
        let existing = Set(profiles.map(\.name))
        var candidate = "\(base) Copy"
        if !existing.contains(candidate) {
            return candidate
        }
        var n = 2
        while existing.contains("\(base) Copy \(n)") {
            n += 1
        }
        candidate = "\(base) Copy \(n)"
        return candidate
    }
}
