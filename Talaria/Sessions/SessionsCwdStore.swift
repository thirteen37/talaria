import Foundation
import HermesKit

// Hermes' on-disk session record doesn't include the cwd the session was created
// in. We persist a Talaria-side mapping so resume can pass the right working
// directory to session/load instead of falling back to $HOME.
@MainActor
final class SessionsCwdStore {
    private let fileURL: URL
    private var cache: [SessionId: String] = [:]

    init(fileURL: URL = SessionsCwdStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    func cwd(for id: SessionId) -> String? {
        cache[id]
    }

    func record(id: SessionId, cwd: String) {
        if cache[id] == cwd {
            return
        }
        cache[id] = cwd
        persist()
    }

    func forget(id: SessionId) {
        guard cache.removeValue(forKey: id) != nil else {
            return
        }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SessionId: String].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort persistence; the next open() will fall back to defaults.
        }
    }

    static var defaultFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Talaria", isDirectory: true)
            .appendingPathComponent("sessions.json", isDirectory: false)
    }
}
