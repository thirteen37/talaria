import Crypto
import Foundation
import NIOSSH

/// A pluggable trust store consulted by ``NIOSSHHostKeyVerifier`` during
/// the SSH handshake. The verifier asks `trust(host:port:key:)` whether the
/// presented host key is already known; on a first-connect TOFU prompt the
/// host app calls `pin(host:port:key:)` after the user confirms.
///
/// Stores never throw on "unknown host" — they return `false`. Throws are
/// reserved for I/O errors (write failure, malformed file) so the verifier
/// can distinguish "we don't know this key yet" from "we couldn't reach the
/// trust store at all."
public protocol HostKeyStore: Sendable {
    func trust(host: String, port: Int, key: NIOSSHPublicKey) throws -> TrustDecision
    func pin(host: String, port: Int, key: NIOSSHPublicKey) throws
}

/// Outcome of a trust lookup. Kept separate from a plain `Bool` so the
/// verifier can distinguish a previously-pinned mismatch (security alert)
/// from a never-seen host (benign TOFU prompt). `.revoked` is fatal: the
/// host app must refuse the connection and cannot offer to re-pin, which
/// mirrors what `/usr/bin/ssh` does for a `@revoked` known_hosts entry.
public enum TrustDecision: Sendable, Equatable {
    case trusted
    case unknown
    case mismatch(pinned: NIOSSHPublicKey)
    case revoked
}

extension NIOSSHPublicKey {
    /// SHA256 fingerprint in the same `SHA256:<base64-no-padding>` form
    /// produced by `ssh-keygen -lf`. Used everywhere we surface a host key
    /// to a human — the TOFU sheet, the audit log, the profile UI.
    ///
    /// `preconditionFailure` on a parse failure is intentional: a silent
    /// empty-buffer hash would collapse *every* malformed key to the
    /// identical `SHA256:47DEQpj8…` digest, defeating the trust-store
    /// equality check (`parsed.sha256Fingerprint == presentedFingerprint`)
    /// and silently merging distinct keys into one trusted identity. If
    /// `String(openSSHPublicKey:)` ever returns a string we can't reparse
    /// for *any* NIO-backed key, that's a NIOSSH-side regression — we'd
    /// rather crash loudly than ship a fingerprint that lies.
    public var sha256Fingerprint: String {
        guard let blob = Self.openSSHWireBlob(self) else {
            preconditionFailure("NIOSSHPublicKey serialized to an unparseable OpenSSH string — refusing to emit a degenerate fingerprint")
        }
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().trimmingCharacters(in: ["="])
        return "SHA256:\(b64)"
    }

    private static func openSSHWireBlob(_ key: NIOSSHPublicKey) -> Data? {
        // NIOSSH's wire-format writer is internal, so we round-trip through
        // the OpenSSH public-key string form. That serialization is stable
        // (used everywhere in the SSH ecosystem) so fingerprint output
        // matches `ssh-keygen -lf` byte-for-byte.
        let openSSH = String(openSSHPublicKey: key)
        let parts = openSSH.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return nil
        }
        return blob
    }
}

// MARK: - Known hosts file (macOS, read-only)

#if os(macOS)

/// Read-only adapter over the user's `~/.ssh/known_hosts`. Honors the
/// macOS-default convention that the NIO transport should respect any host
/// the user has already trusted via system-ssh. The store never *writes* to
/// `known_hosts` — new pins go to the JSON store so we don't co-opt files
/// owned by another tool's UX.
public struct KnownHostsFileStore: HostKeyStore {
    public let path: URL

    public init(path: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/known_hosts")) {
        self.path = path
    }

    public func trust(host: String, port: Int, key: NIOSSHPublicKey) throws -> TrustDecision {
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
            return .unknown
        }
        let presentedFingerprint = key.sha256Fingerprint
        var trustVerdict: TrustDecision = .unknown
        var sawMatchingHostnameWithDifferentKey: NIOSSHPublicKey?
        // Scan the *entire* file so a later `@revoked` line for the
        // presented key overrides an earlier plain trust line. The
        // common revocation flow is to append `@revoked …` rather than
        // edit the original entry out, so an early-exit on first match
        // would silently miss the revocation. OpenSSH's semantics
        // require @revoked to win regardless of position in the file.
        for rawLine in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Strip optional `@marker` prefix. The three markers OpenSSH
            // defines are `@cert-authority`, `@revoked`, and (in older
            // releases) `@deprecated`. We honor `@revoked` because it has
            // *deny* semantics — silently skipping it would let an
            // explicitly-revoked key route through the TOFU prompt and be
            // re-trusted, which is exactly what `/usr/bin/ssh` refuses to
            // do. `@cert-authority` is parsed but currently treated as an
            // unrecognized entry (we don't verify CA chains in v1).
            var marker: String? = nil
            if line.hasPrefix("@") {
                guard let space = line.firstIndex(of: " ") else { continue }
                marker = String(line[line.index(after: line.startIndex)..<space])
                line = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            }

            // Skip hashed-host entries (`|1|...|...`). The NIO path can't
            // resolve these without implementing the HMAC scheme, so we
            // treat them as opaque and let TOFU pin a fresh entry in the
            // JSON store. Documented gap vs. system-ssh.
            let firstField = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            if firstField.hasPrefix("|") { continue }
            guard let space = line.firstIndex(of: " ") else { continue }
            let hostList = String(line[..<space])
            line = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            guard Self.hostListMatches(hostList, host: host, port: port) else { continue }
            guard let parsed = try? NIOSSHPublicKey(openSSHPublicKey: line) else { continue }

            switch marker {
            case "revoked":
                if parsed.sha256Fingerprint == presentedFingerprint {
                    // Hard fail — short-circuit. Nothing later in the
                    // file can override a revocation of the presented key.
                    return .revoked
                }
                // Revoked but for a different key — irrelevant to *this*
                // connection. Keep scanning.
                continue
            case "cert-authority":
                // CA-signed key verification isn't implemented in v1.
                // Skip so the entry doesn't masquerade as a trusted host
                // key match.
                continue
            case .some, .none:
                break
            }

            if parsed.sha256Fingerprint == presentedFingerprint {
                // Stash the trust verdict but **keep scanning** — a
                // later `@revoked` line for this same key must still be
                // honored. Without the full-file scan, the common
                // append-only revocation flow would silently bypass.
                trustVerdict = .trusted
            } else if case .unknown = trustVerdict {
                // Only record a mismatch if we haven't already found a
                // trust verdict — a present trust on the exact key
                // outranks a same-host-different-key mismatch.
                sawMatchingHostnameWithDifferentKey = parsed
            }
        }
        if case .trusted = trustVerdict {
            return .trusted
        }
        if let pinned = sawMatchingHostnameWithDifferentKey {
            return .mismatch(pinned: pinned)
        }
        return .unknown
    }

    public func pin(host: String, port: Int, key: NIOSSHPublicKey) throws {
        // System-owned file; intentionally read-only here. New pins go to
        // PinnedHostKeyStore so we never touch a file managed by another
        // tool's UX.
        throw HostKeyStoreError.notWritable
    }

    static func hostListMatches(_ hostList: String, host: String, port: Int) -> Bool {
        // OpenSSH treats `known_hosts` hostnames case-insensitively, and
        // `PinnedHostKeyStore` already normalizes to lowercase before
        // lookup/pin. Mirror that here — otherwise a profile saved as
        // `Example.COM` whose `~/.ssh/known_hosts` line is `example.com`
        // would fall through to TOFU and get re-pinned under the
        // lowercase form, masking what should be a silent reuse of the
        // system-ssh trust.
        let normalizedHost = host.lowercased()
        let needle = port == 22 ? normalizedHost : "[\(normalizedHost)]:\(port)"
        for entry in hostList.split(separator: ",") {
            let candidate = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if candidate == needle { return true }
            if port == 22, candidate == normalizedHost { return true }
        }
        return false
    }
}

#endif

// MARK: - Pinned host key store (cross-platform JSON)

public enum HostKeyStoreError: Error, Equatable, Sendable, LocalizedError {
    case notWritable
    case corruptStore(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notWritable: return "Host key store is read-only."
        case let .corruptStore(message): return "Host key store is corrupt: \(message)"
        case let .ioFailed(message): return "Host key store I/O failed: \(message)"
        }
    }
}

/// Cross-platform JSON-backed trust store. Used as the *write* target for
/// new pins (TOFU confirmations from the host app) and as the iOS-side
/// source of truth, since `~/.ssh/known_hosts` doesn't exist there.
public final class PinnedHostKeyStore: HostKeyStore, @unchecked Sendable {
    public let path: URL
    private let lock = NSLock()

    public init(path: URL = PinnedHostKeyStore.defaultPath) {
        self.path = path
    }

    public static var defaultPath: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Talaria", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("known_hosts.json", isDirectory: false)
    }

    public func trust(host: String, port: Int, key: NIOSSHPublicKey) throws -> TrustDecision {
        lock.lock()
        defer { lock.unlock() }
        let entries = try loadEntriesLocked()
        let needleHost = Self.normalizedHost(host)
        let presentedOpenSSH = String(openSSHPublicKey: key)
        if let match = entries.first(where: { $0.host == needleHost && $0.port == port }) {
            if match.openSSHKey == presentedOpenSSH {
                return .trusted
            }
            if let pinned = try? NIOSSHPublicKey(openSSHPublicKey: match.openSSHKey) {
                return .mismatch(pinned: pinned)
            }
            throw HostKeyStoreError.corruptStore("pinned key for \(host) failed to parse")
        }
        return .unknown
    }

    public func pin(host: String, port: Int, key: NIOSSHPublicKey) throws {
        // Hold the lock across the full read-modify-write so two concurrent
        // pins for different hosts can't both load the same baseline,
        // append their own entry, and have the second save overwrite the
        // first. The previous split-helper approach released the lock
        // between load and save, creating exactly that lost-update window.
        lock.lock()
        defer { lock.unlock() }
        var entries = try loadEntriesLocked()
        let needleHost = Self.normalizedHost(host)
        entries.removeAll { $0.host == needleHost && $0.port == port }
        entries.append(Entry(
            host: needleHost,
            port: port,
            openSSHKey: String(openSSHPublicKey: key),
            sha256Fingerprint: key.sha256Fingerprint,
            pinnedAt: Date()
        ))
        try saveEntriesLocked(entries)
    }

    public func allPins() throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return try loadEntriesLocked()
    }

    // The `*Locked` suffix is a contract reminder: callers MUST hold
    // `lock` for the duration. We hand-roll the contract rather than
    // wrapping each call in another `lock.lock()` so the multi-step
    // `pin` flow can stay atomic.

    private func loadEntriesLocked() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Entry].self, from: data)
        } catch let decodeError as DecodingError {
            throw HostKeyStoreError.corruptStore(String(describing: decodeError))
        } catch {
            throw HostKeyStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func saveEntriesLocked(_ entries: [Entry]) throws {
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: path, options: .atomic)
        } catch {
            throw HostKeyStoreError.ioFailed(error.localizedDescription)
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased()
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var host: String
        public var port: Int
        public var openSSHKey: String
        public var sha256Fingerprint: String
        public var pinnedAt: Date

        public init(host: String, port: Int, openSSHKey: String, sha256Fingerprint: String, pinnedAt: Date) {
            self.host = host
            self.port = port
            self.openSSHKey = openSSHKey
            self.sha256Fingerprint = sha256Fingerprint
            self.pinnedAt = pinnedAt
        }
    }
}

// MARK: - Composite store

/// Consults a chain of read stores in order, but only writes to the first
/// writable one (`PinnedHostKeyStore`). The macOS production wiring layers
/// `KnownHostsFileStore` over `PinnedHostKeyStore` so previously
/// system-ssh-trusted hosts connect silently while new pins land in the
/// Talaria-owned file.
public final class CompositeHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let readers: [HostKeyStore]
    private let writer: HostKeyStore

    public init(readers: [HostKeyStore], writer: HostKeyStore) {
        self.readers = readers
        self.writer = writer
    }

    public func trust(host: String, port: Int, key: NIOSSHPublicKey) throws -> TrustDecision {
        var lastMismatch: TrustDecision?
        // First pass: a `.revoked` outcome from *any* reader must override
        // any other reader's `.trusted`. Otherwise an attacker who could
        // get a key into the pinned store would defeat a `@revoked` line
        // the user added to `~/.ssh/known_hosts`.
        var decisions: [TrustDecision] = []
        for reader in readers {
            decisions.append(try reader.trust(host: host, port: port, key: key))
        }
        if decisions.contains(.revoked) {
            return .revoked
        }
        for decision in decisions {
            switch decision {
            case .trusted: return .trusted
            case .unknown: continue
            case let .mismatch(pinned):
                // Hold onto the mismatch but keep scanning: another reader
                // (e.g. PinnedHostKeyStore behind KnownHostsFileStore) might
                // still recognize the *presented* key. Only surface the
                // mismatch if no reader recognizes the presented key.
                lastMismatch = .mismatch(pinned: pinned)
            case .revoked:
                return .revoked // unreachable — already short-circuited
            }
        }
        return lastMismatch ?? .unknown
    }

    public func pin(host: String, port: Int, key: NIOSSHPublicKey) throws {
        try writer.pin(host: host, port: port, key: key)
    }
}
