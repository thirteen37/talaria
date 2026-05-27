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
final class NIOSSHHostKeyVerifier: NIOSSHClientServerAuthenticationDelegate {
    private let store: HostKeyStore
    private let host: String
    private let port: Int

    init(store: HostKeyStore, host: String, port: Int) {
        self.store = store
        self.host = host
        self.port = port
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
            validationCompletePromise.succeed(())
        case .unknown:
            validationCompletePromise.fail(SSHTransportError.hostKeyUnknown(fingerprint: hostKey.sha256Fingerprint))
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
