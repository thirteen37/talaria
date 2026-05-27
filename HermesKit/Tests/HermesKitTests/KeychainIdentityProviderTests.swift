import Foundation
import Testing
@testable import HermesKit

/// v1 contract for the Keychain provider: it surfaces a typed error
/// instead of crashing, since the actual Keychain wiring lands with the
/// future iOS app target. When that lands, replace these tests with the
/// real round-trip (store an encrypted OpenSSH ed25519 key, fetch it
/// back, verify `needsPassphrase` is thrown when the passphrase is
/// missing/wrong).
@Suite
struct KeychainIdentityProviderTests {
    @Test
    func throwsWhenProfileHasNoReference() {
        let provider = KeychainIdentityProvider()
        let profile = ServerProfile(name: "Box", kind: .ssh, host: "h")
        do {
            _ = try provider.privateKey(for: profile, passphrase: nil)
            Issue.record("Expected throw")
        } catch let SSHTransportError.authFailed(message) {
            #expect(message.contains("keychainKeyReference"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func throwsTodoErrorWhenReferenceSetButKeychainUnwired() {
        let provider = KeychainIdentityProvider()
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "h",
            keychainKeyReference: "talaria.profile.test"
        )
        do {
            _ = try provider.privateKey(for: profile, passphrase: nil)
            Issue.record("Expected throw")
        } catch let SSHTransportError.authFailed(message) {
            #expect(message.contains("not yet wired"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
