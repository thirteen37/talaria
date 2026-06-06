import Foundation
import HermesKit

/// Thread-safe holder for a window's live Hermes version, shared between the
/// `ServerWindowHarness` (writer, on `refreshLiveVersion()`) and the chat
/// backend factory (reader, at session-open time). Decouples the two: the
/// factory is built before the dashboard — and thus the version — is known, so
/// it can't capture the harness directly.
final class LiveVersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var version: HermesVersion?

    func set(_ version: HermesVersion?) {
        lock.lock()
        self.version = version
        lock.unlock()
    }

    func get() -> HermesVersion? {
        lock.lock()
        defer { lock.unlock() }
        return version
    }
}
