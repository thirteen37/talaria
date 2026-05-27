import NIOCore
import NIOSSH

/// Bridges ``SSHCredentialProvider`` into NIOSSH's user-auth state machine.
///
/// We resolve the private key **once** at construction (so any
/// `.needsPassphrase` error surfaces from the transport factory, not from
/// inside the NIO event loop) and then replay it on every auth challenge
/// the server issues. The delegate offers `.privateKey` once if the
/// server advertises that method, then nil (terminate). It deliberately
/// does **not** attempt `.none` (NIOSSH's
/// ``NIOSSHAvailableUserAuthenticationMethods`` doesn't expose it as an
/// option in this release) and does **not** prompt for passwords —
/// the NIO transport is publickey-only in v1.
final class NIOSSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var offeredPublicKey = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !offeredPublicKey, availableMethods.contains(.publicKey) {
            offeredPublicKey = true
            let key = NIOSSHUserAuthenticationOffer.Offer.PrivateKey(privateKey: privateKey)
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(key))
            )
            return
        }
        // We've offered everything we have — succeeding the promise with nil
        // tells NIOSSH to terminate auth. The server's overall auth failure
        // surfaces as a connection close, which the transport translates
        // into `.authFailed`.
        nextChallengePromise.succeed(nil)
    }
}
