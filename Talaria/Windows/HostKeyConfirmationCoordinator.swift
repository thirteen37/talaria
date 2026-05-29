import HermesKit
import SwiftUI

/// Bridges the NIO-SSH host-key verifier's trust-on-first-use callback to a
/// SwiftUI confirmation prompt.
///
/// The verifier runs on a NIO event loop; when it meets an unknown host key
/// it calls ``confirm(host:port:fingerprint:)`` (which hops to the main
/// actor), publishes a ``Request``, and suspends on a continuation until the
/// UI resolves it. On iOS this is the only way to trust a new host — there's
/// no `~/.ssh/known_hosts` to seed the pinned store.
@MainActor
@Observable
final class HostKeyConfirmationCoordinator {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let port: Int
        let fingerprint: String
    }

    private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Confirmer handed to ``NIOSSHTransport`` / ``NIOSSHCatTransfer``. Safe to
    /// call from the event loop — it suspends until the user decides.
    func confirm(host: String, port: Int, fingerprint: String) async -> Bool {
        // Serialize: if a prompt is already up, deny the newcomer rather than
        // clobbering the live continuation. In practice connections are
        // attempted one at a time per window.
        if pending != nil { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = Request(host: host, port: port, fingerprint: fingerprint)
        }
    }

    /// Resolves the active prompt. Idempotent — a second call (e.g. the alert
    /// dismissing after a button already resolved) is a no-op.
    func resolve(_ trust: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: trust)
    }
}
