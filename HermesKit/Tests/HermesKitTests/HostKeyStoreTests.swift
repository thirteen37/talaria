import Crypto
import Foundation
import NIOSSH
import Testing
@testable import HermesKit

/// Two ed25519 host keys fabricated for these tests. The public-key strings
/// are deterministic: we generate the private key in-process (so the
/// fixture stays self-contained) and round-trip through
/// `String(openSSHPublicKey:)`.
private struct GeneratedHostKey {
    let privateKey: NIOSSHPrivateKey
    let publicKey: NIOSSHPublicKey
    var openSSHLine: String { String(openSSHPublicKey: publicKey) }
}

private func makeHostKey() -> GeneratedHostKey {
    let priv = Curve25519.Signing.PrivateKey()
    let nio = NIOSSHPrivateKey(ed25519Key: priv)
    return GeneratedHostKey(privateKey: nio, publicKey: nio.publicKey)
}

@Suite
struct HostKeyStoreTests {
    @Test
    func sha256FingerprintHasExpectedShape() {
        let key = makeHostKey()
        let fp = key.publicKey.sha256Fingerprint
        #expect(fp.hasPrefix("SHA256:"))
        // Stable length: base64 of 32 raw bytes without padding = 43 chars.
        #expect(fp.count == "SHA256:".count + 43)
    }

    @Test
    func pinnedStoreInitiallyUnknownThenTrustedAfterPin() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = PinnedHostKeyStore(path: tmpDir.appendingPathComponent("known_hosts.json"))
        let key = makeHostKey()

        let initial = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(initial == .unknown)

        try store.pin(host: "example.com", port: 22, key: key.publicKey)
        let afterPin = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(afterPin == .trusted)
    }

    @Test
    func pinnedStoreReportsMismatchWhenKeyChanges() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = PinnedHostKeyStore(path: tmpDir.appendingPathComponent("known_hosts.json"))
        let original = makeHostKey()
        let attacker = makeHostKey()

        try store.pin(host: "example.com", port: 22, key: original.publicKey)
        let result = try store.trust(host: "example.com", port: 22, key: attacker.publicKey)
        if case let .mismatch(pinned) = result {
            #expect(pinned.sha256Fingerprint == original.publicKey.sha256Fingerprint)
        } else {
            Issue.record("Expected .mismatch, got \(result)")
        }
    }

    @Test
    func pinnedStorePersistsAcrossInstances() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("known_hosts.json")
        let store1 = PinnedHostKeyStore(path: path)
        let key = makeHostKey()
        try store1.pin(host: "example.com", port: 2222, key: key.publicKey)

        let store2 = PinnedHostKeyStore(path: path)
        let result = try store2.trust(host: "example.com", port: 2222, key: key.publicKey)
        #expect(result == .trusted)
    }

    @Test
    func pinnedStoreSeparatesByHostAndPort() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let store = PinnedHostKeyStore(path: tmpDir.appendingPathComponent("known_hosts.json"))
        let key = makeHostKey()
        try store.pin(host: "a.example", port: 22, key: key.publicKey)

        let other = try store.trust(host: "b.example", port: 22, key: key.publicKey)
        #expect(other == .unknown)
        let differentPort = try store.trust(host: "a.example", port: 2222, key: key.publicKey)
        #expect(differentPort == .unknown)
    }

    #if os(macOS)
    @Test
    func knownHostsFileMatchesExplicitHost() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("known_hosts")
        let key = makeHostKey()
        let line = "example.com \(key.openSSHLine)\n"
        try line.write(to: path, atomically: true, encoding: .utf8)

        let store = KnownHostsFileStore(path: path)
        let result = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(result == .trusted)
    }

    @Test
    func knownHostsFileSkipsHashedEntries() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("known_hosts")
        let key = makeHostKey()
        // Hashed entries the parser intentionally skips, so the host
        // surfaces as `.unknown` (falling through to the TOFU prompt
        // backed by the pinned store).
        let line = "|1|abcdef|ghijkl= \(key.openSSHLine)\n"
        try line.write(to: path, atomically: true, encoding: .utf8)

        let store = KnownHostsFileStore(path: path)
        let result = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(result == .unknown)
    }

    @Test
    func knownHostsFileHonorsBracketedPortNotation() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("known_hosts")
        let key = makeHostKey()
        let line = "[example.com]:2222 \(key.openSSHLine)\n"
        try line.write(to: path, atomically: true, encoding: .utf8)

        let store = KnownHostsFileStore(path: path)
        let port22 = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(port22 == .unknown)
        let port2222 = try store.trust(host: "example.com", port: 2222, key: key.publicKey)
        #expect(port2222 == .trusted)
    }

    @Test
    func knownHostsFileRevokedTakesPrecedenceOverPin() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let key = makeHostKey()
        let knownHostsPath = tmpDir.appendingPathComponent("known_hosts")
        // OpenSSH `@revoked` semantics: a key listed here must be hard
        // rejected, even if our pinned store happens to trust it. Without
        // the dedicated handling, the NIO path would skip the line and
        // route through TOFU — that's exactly the silent bypass we
        // closed.
        try "@revoked example.com \(key.openSSHLine)\n".write(to: knownHostsPath, atomically: true, encoding: .utf8)
        let pinned = PinnedHostKeyStore(path: tmpDir.appendingPathComponent("known_hosts.json"))
        try pinned.pin(host: "example.com", port: 22, key: key.publicKey)
        let composite = CompositeHostKeyStore(
            readers: [KnownHostsFileStore(path: knownHostsPath), pinned],
            writer: pinned
        )
        let result = try composite.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(result == .revoked)
    }

    @Test
    func knownHostsFileRevokedDoesNotAffectOtherKeys() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let revokedKey = makeHostKey()
        let freshKey = makeHostKey()
        let knownHostsPath = tmpDir.appendingPathComponent("known_hosts")
        try "@revoked example.com \(revokedKey.openSSHLine)\n".write(to: knownHostsPath, atomically: true, encoding: .utf8)
        let store = KnownHostsFileStore(path: knownHostsPath)
        // A different presented key should fall through to `.unknown` —
        // the @revoked line is targeted, not a blanket host ban.
        let result = try store.trust(host: "example.com", port: 22, key: freshKey.publicKey)
        #expect(result == .unknown)
    }

    @Test
    func knownHostsFileMatchesAreCaseInsensitive() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let path = tmpDir.appendingPathComponent("known_hosts")
        let key = makeHostKey()
        // OpenSSH treats hostnames case-insensitively. A profile saved as
        // "Example.COM" must still match a `~/.ssh/known_hosts` line
        // written by system-ssh as "example.com" — otherwise the user is
        // forced through TOFU and the key duplicates into the pinned
        // store under the lowercased form.
        try "example.com \(key.openSSHLine)\n".write(to: path, atomically: true, encoding: .utf8)
        let store = KnownHostsFileStore(path: path)
        let result = try store.trust(host: "Example.COM", port: 22, key: key.publicKey)
        #expect(result == .trusted)
    }

    @Test
    func knownHostsFileRevokedAfterTrustLineStillWins() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let key = makeHostKey()
        let knownHostsPath = tmpDir.appendingPathComponent("known_hosts")
        // Append-only revocation: a plain trust line precedes a
        // `@revoked` line for the same key. OpenSSH treats this as a
        // revocation regardless of order; an early-exit on the trust
        // line would silently bypass the revocation, which is the most
        // common way users revoke keys (append rather than edit).
        let contents = """
        example.com \(key.openSSHLine)
        @revoked example.com \(key.openSSHLine)
        """
        try contents.write(to: knownHostsPath, atomically: true, encoding: .utf8)
        let store = KnownHostsFileStore(path: knownHostsPath)
        let result = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(result == .revoked)
    }

    @Test
    func knownHostsFileCertAuthorityIsSkipped() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let key = makeHostKey()
        let knownHostsPath = tmpDir.appendingPathComponent("known_hosts")
        // CA-signed verification isn't implemented in v1 — the entry must
        // not masquerade as a trusted plain host key.
        try "@cert-authority example.com \(key.openSSHLine)\n".write(to: knownHostsPath, atomically: true, encoding: .utf8)
        let store = KnownHostsFileStore(path: knownHostsPath)
        let result = try store.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(result == .unknown)
    }

    @Test
    func compositeStoreReturnsTrustedFromAnyReader() throws {
        let tmpDir = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let key = makeHostKey()
        // Layout the macOS production wiring uses: known_hosts (system-ssh
        // trust) first, then our own pinned store. The composite must
        // accept either source.
        let knownHostsPath = tmpDir.appendingPathComponent("known_hosts")
        try "example.com \(key.openSSHLine)\n".write(to: knownHostsPath, atomically: true, encoding: .utf8)
        let pinned = PinnedHostKeyStore(path: tmpDir.appendingPathComponent("known_hosts.json"))
        let composite = CompositeHostKeyStore(
            readers: [KnownHostsFileStore(path: knownHostsPath), pinned],
            writer: pinned
        )
        let result = try composite.trust(host: "example.com", port: 22, key: key.publicKey)
        #expect(result == .trusted)
    }
    #endif

    private func makeTmpDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HermesKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
