import Foundation
import NIOSSH
import Testing
@testable import HermesKit

/// Contract for the probe-time password provider: it offers a just-typed
/// password to the SSH auth delegate without that password having been saved
/// to the Keychain yet (the new/unsaved-profile probe path), and falls back to
/// the wrapped base provider's Keychain lookup when the field is empty (the
/// saved-profile probe path). Key resolution is always delegated to the base.
@Suite
struct ExplicitPasswordProviderTests {
    /// Returns canned values so we can assert the wrapper delegates to — and
    /// falls back to — its base.
    struct StubBase: SSHCredentialProvider {
        var passwordToReturn: String?
        func privateKey(for profile: ServerProfile, passphrase: String?) throws -> NIOSSHPrivateKey? {
            nil
        }
        func password(for profile: ServerProfile) throws -> String? {
            passwordToReturn
        }
    }

    private func passwordProfile() -> ServerProfile {
        ServerProfile(name: "Box", kind: .ssh, host: "h", authMethod: .password)
    }

    @Test
    func returnsInjectedPasswordForPasswordProfile() throws {
        // No Keychain reference on the profile — the injected password is the
        // only source, mirroring a brand-new/unsaved password profile.
        let provider = ExplicitPasswordProvider(password: "hunter2", base: StubBase())
        #expect(try provider.password(for: passwordProfile()) == "hunter2")
    }

    @Test
    func emptyInjectedPasswordFallsBackToBase() throws {
        let provider = ExplicitPasswordProvider(password: "", base: StubBase(passwordToReturn: "stored"))
        #expect(try provider.password(for: passwordProfile()) == "stored")
    }

    @Test
    func returnsNilForIdentityFileProfile() throws {
        let provider = ExplicitPasswordProvider(password: "hunter2", base: StubBase())
        let profile = ServerProfile(name: "Box", kind: .ssh, host: "h", authMethod: .identityFile)
        #expect(try provider.password(for: profile) == nil)
    }

    @Test
    func privateKeyDelegatesToBase() throws {
        // The wrapper holds no key of its own; whatever the base yields (here
        // nil) is what comes back, proving the call is delegated.
        let provider = ExplicitPasswordProvider(password: "hunter2", base: StubBase())
        #expect(try provider.privateKey(for: passwordProfile(), passphrase: nil) == nil)
    }
}
