import NIOCore
import NIOSSH

/// Bridges ``SSHCredentialProvider`` into NIOSSH's user-auth state machine.
///
/// We resolve credentials **once** at construction (so any
/// `.needsPassphrase` error surfaces from the transport factory, not from
/// inside the NIO event loop) and then replay them on every auth challenge
/// the server issues. The delegate offers `.privateKey` first (if a key is
/// configured and the server advertises that method) and falls back to
/// `.password` (if a password is configured and the server advertises it).
/// Once everything has been offered, it terminates the auth dance.
/// `.none` isn't exposed by NIOSSH's available-methods set in this
/// release, so we never try it.
final class NIOSSHAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey?
    private let password: String?
    private var offeredPublicKey = false
    private var offeredPassword = false

    init(username: String, privateKey: NIOSSHPrivateKey?, password: String?) {
        self.username = username
        self.privateKey = privateKey
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !offeredPublicKey, let privateKey, availableMethods.contains(.publicKey) {
            offeredPublicKey = true
            HermesLog.transport.info("auth: offering publickey")
            let key = NIOSSHUserAuthenticationOffer.Offer.PrivateKey(privateKey: privateKey)
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(key))
            )
            return
        }
        if !offeredPassword, let password, availableMethods.contains(.password) {
            offeredPassword = true
            HermesLog.transport.info("auth: offering password")
            let pwd = NIOSSHUserAuthenticationOffer.Offer.Password(password: password)
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(pwd))
            )
            return
        }
        // We've offered everything we have — succeeding the promise with nil
        // tells NIOSSH to terminate auth. The server's overall auth failure
        // surfaces as a connection close, which the transport translates
        // into `.authFailed`.
        HermesLog.transport.error("auth: no methods left to offer (server advertised: \(String(describing: availableMethods), privacy: .public)); had key=\(self.privateKey != nil), password=\(self.password != nil)")
        nextChallengePromise.succeed(nil)
    }
}
