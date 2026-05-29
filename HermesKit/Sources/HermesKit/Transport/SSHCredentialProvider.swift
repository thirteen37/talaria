import Foundation
import NIOSSH

/// Provides the SSH client identity that ``NIOSSHAuthDelegate`` offers to
/// the server. Implementations decide where the private key comes from
/// (a file on disk on macOS, the Keychain on iOS) and how to handle
/// passphrase-protected keys. Implementations may also surface a stored
/// password for profiles that opt into password auth.
///
/// The protocol is intentionally synchronous + throwing: the auth delegate
/// runs on a NIO event loop and we don't want to block it on Keychain or
/// disk I/O. Callers fetch the credentials once at transport construction
/// and pass them in; if a key is encrypted and no passphrase was supplied,
/// the provider throws ``SSHTransportError/needsPassphrase(keyPath:)`` so
/// the host app can prompt and re-invoke the transport factory.
public protocol SSHCredentialProvider: Sendable {
    /// Returns the private key configured for the profile, or nil when the
    /// profile is set up for password-only auth.
    func privateKey(for profile: ServerProfile, passphrase: String?) throws -> NIOSSHPrivateKey?

    /// Returns the password configured for the profile, or nil when no
    /// password is stored. Default implementation returns nil so existing
    /// providers continue to compile unchanged.
    func password(for profile: ServerProfile) throws -> String?
}

extension SSHCredentialProvider {
    public func password(for profile: ServerProfile) throws -> String? { nil }
}

// MARK: - File-backed provider (macOS today; works anywhere `profile.identityFile` is readable)

/// Reads `profile.identityFile` from disk and parses the OpenSSH private
/// key. This is the macOS production path — it mirrors what the user
/// already pointed `~/.ssh/...` at via the profile editor.
///
/// **v1 passphrase handling:** the in-tree OpenSSH key parser does **not**
/// implement bcrypt-KDF + aes256-ctr decryption yet, so encrypted keys
/// can't be unlocked at runtime even when the host app supplies a
/// passphrase. We still throw the typed `.needsPassphrase(keyPath:)` so
/// the host app can surface an actionable error that points the user at
/// the documented workaround: re-emit the key in unencrypted form with
/// `ssh-keygen -p -m OPENSSH -f <path> -N ''`, then re-add it to the
/// profile. The `passphrase` parameter is kept on the protocol for the
/// future Keychain path and for the eventual KDF implementation.
public struct FileIdentityProvider: SSHCredentialProvider {
    public init() {}

    public func privateKey(for profile: ServerProfile, passphrase: String?) throws -> NIOSSHPrivateKey? {
        // Password-auth profiles don't need a key. Return nil so the
        // transport falls through to ``password(for:)``.
        if profile.authMethod == .password { return nil }
        guard let raw = profile.identityFile, !raw.isEmpty else {
            // No identityFile configured — let the transport decide whether
            // to fail or fall back to another method (password).
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let pem: String
        do {
            pem = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SSHTransportError.authFailed("could not read identity file at \(expanded): \(error.localizedDescription)")
        }
        do {
            return try OpenSSHPrivateKeyParser.parse(pem)
        } catch OpenSSHPrivateKeyParser.ParseError.encryptedKeyNotSupported {
            // Surface the typed error so the host app can show an
            // actionable sheet. The `passphrase` parameter is accepted by
            // the protocol but not yet honored — see the v1 caveat in
            // the type doc above and `docs/security.md`.
            throw SSHTransportError.needsPassphrase(keyPath: expanded)
        } catch let error as OpenSSHPrivateKeyParser.ParseError {
            throw SSHTransportError.authFailed(error.description)
        } catch {
            throw SSHTransportError.authFailed(error.localizedDescription)
        }
    }

    public func password(for profile: ServerProfile) throws -> String? {
        guard profile.authMethod == .password,
              let reference = profile.passwordKeychainReference,
              !reference.isEmpty else {
            return nil
        }
        // ``PasswordKeychain`` is iOS-only; on macOS it always returns nil
        // (system-ssh handles its own credentials).
        return PasswordKeychain.get(reference: reference)
    }
}

// MARK: - Keychain provider (cross-platform; stubbed for v1)

/// Cross-platform provider that reads the PEM/OpenSSH blob from the
/// Keychain. The Keychain entry is keyed by ``ServerProfile/keychainKeyReference``.
///
/// **v1 status:** the iOS app target doesn't exist yet, so this provider is
/// not wired into any host today. The protocol surface and `import` flow
/// are sketched here so a later sprint can implement the actual Keychain
/// read without re-shaping the transport. Calling `privateKey(...)` on
/// the unimplemented path throws ``SSHTransportError/authFailed`` rather
/// than `fatalError`-ing so test harnesses can exercise the call site.
public struct KeychainIdentityProvider: SSHCredentialProvider {
    public init() {}

    public func privateKey(for profile: ServerProfile, passphrase: String?) throws -> NIOSSHPrivateKey? {
        guard let reference = profile.keychainKeyReference, !reference.isEmpty else {
            throw SSHTransportError.authFailed("profile has no keychainKeyReference")
        }
        // Real Keychain wiring lands with the iOS app target. Until then we
        // return a typed error so the host app can fall back to either the
        // file provider or a manual passphrase prompt.
        throw SSHTransportError.authFailed("Keychain identity provider is not yet wired (reference: \(reference))")
    }

    /// Placeholder for the iOS UI to populate the Keychain. Stubbed for
    /// the same reason as `privateKey(...)`: the iOS app doesn't exist yet,
    /// but the call site needs to be discoverable from the future UI work.
    public func `import`(profile: ServerProfile, openSSHBlob: String, passphrase: String?) throws {
        guard profile.keychainKeyReference != nil else {
            throw SSHTransportError.authFailed("profile has no keychainKeyReference")
        }
        // Parse to validate the blob before storing — we'd rather reject at
        // import time than surface a parse error on first connect.
        _ = try OpenSSHPrivateKeyParser.parse(openSSHBlob)
        // Actual Keychain write lands with the iOS app target.
    }
}
