import Foundation
import HermesKit
import SwiftUI

/// Tracks the most-recently-opened server profile IDs in `UserDefaults`.
/// Kept tiny because it only needs to feed the menu; UI state lives in
/// ``ProfileDirectory``.
@MainActor
@Observable
final class RecentServers {
    static let maxCount = 5
    private static let key = "recentServerIds"

    private(set) var ids: [UUID]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        self.ids = stored.compactMap(UUID.init)
    }

    func record(_ id: UUID) {
        var updated = ids.filter { $0 != id }
        updated.insert(id, at: 0)
        if updated.count > Self.maxCount {
            updated = Array(updated.prefix(Self.maxCount))
        }
        ids = updated
        defaults.set(updated.map(\.uuidString), forKey: Self.key)
    }

    func clear() {
        ids = []
        defaults.removeObject(forKey: Self.key)
    }
}
