import NIOCore
import NIOSSH

/// Bridges ``HostKeyStore`` into NIOSSH's host-key validation callback.
///
/// On `.trusted` we succeed the promise and the handshake proceeds. On
/// `.unknown` we fail with ``SSHTransportError/hostKeyUnknown(fingerprint:)``
/// so the host app can show a TOFU confirm sheet, call
/// ``PinnedHostKeyStore/pin(host:port:key:)``, and re-invoke the transport
/// factory. On `.mismatch` we fail with
/// ``SSHTransportError/hostKeyMismatch(presented:pinned:)`` — never silently
/// re-pin, since that would defeat the purpose of pinning.
/// `Sendable` (no `@unchecked` needed): every stored property is an immutable
/// `let` of a `Sendable` type (`HostKeyStore` is `Sendable`, `HostKeyConfirmer`
/// is a `@Sendable` closure). The conformance lets the verifier be captured by
/// the `@Sendable` channel initializer that builds the `SSHClientConfiguration`.
final class NIOSSHHostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let store: HostKeyStore
    private let host: String
    private let port: Int
    private let confirmUnknown: HostKeyConfirmer?

    init(store: HostKeyStore, host: String, port: Int, confirmUnknown: HostKeyConfirmer? = nil) {
        self.store = store
        self.host = host
        self.port = port
        self.confirmUnknown = confirmUnknown
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let decision: TrustDecision
        do {
            decision = try store.trust(host: host, port: port, key: hostKey)
        } catch {
            validationCompletePromise.fail(error)
            return
        }
        switch decision {
        case .trusted:
            HermesLog.transport.info("host key trusted for \(self.host, privacy: .public):\(self.port)")
            validationCompletePromise.succeed(())
        case .unknown:
            let fingerprint = hostKey.sha256Fingerprint
            HermesLog.transport.info("host key unknown (\(fingerprint, privacy: .public)) — \(self.confirmUnknown == nil ? "no confirmer, failing" : "asking user", privacy: .public)")
            guard let confirmUnknown else {
                // No interactive trust path (e.g. headless): hard-fail so the
                // host app can surface the fingerprint. On iOS a confirmer is
                // always supplied, so this branch is the macOS/test default.
                validationCompletePromise.fail(SSHTransportError.hostKeyUnknown(fingerprint: fingerprint))
                return
            }
            // Hop off the event loop to ask the user (TOFU). Pin + succeed on
            // approval; otherwise abort with the same unknown-key error. The
            // EventLoopPromise is thread-safe, so resolving it from this Task
            // is fine. `hostKey` and `store` are Sendable.
            let host = self.host
            let port = self.port
            let store = self.store
            Task {
                let approved = await confirmUnknown(host, port, fingerprint)
                if approved {
                    do {
                        try store.pin(host: host, port: port, key: hostKey)
                        HermesLog.transport.info("host key approved + pinned for \(host, privacy: .public):\(port)")
                        validationCompletePromise.succeed(())
                    } catch {
                        HermesLog.transport.error("host key pin failed: \(String(describing: error), privacy: .public)")
                        validationCompletePromise.fail(error)
                    }
                } else {
                    HermesLog.transport.info("host key rejected by user")
                    validationCompletePromise.fail(SSHTransportError.hostKeyUnknown(fingerprint: fingerprint))
                }
            }
        case let .mismatch(pinned):
            validationCompletePromise.fail(SSHTransportError.hostKeyMismatch(
                presented: hostKey.sha256Fingerprint,
                pinned: pinned.sha256Fingerprint
            ))
        case .revoked:
            // Hard fail with a dedicated error case so the host app's TOFU
            // sheet never offers a "trust anyway" button — the whole point
            // of `@revoked` is that this key is deny-listed.
            validationCompletePromise.fail(SSHTransportError.hostKeyRevoked(fingerprint: hostKey.sha256Fingerprint))
        }
    }
}
