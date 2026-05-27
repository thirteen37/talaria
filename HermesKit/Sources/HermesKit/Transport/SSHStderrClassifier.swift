import Foundation

/// Typed SSH-layer failure surfaced to the UI. Cases are shared between the
/// system-ssh transport (which classifies stderr text from `/usr/bin/ssh`) and
/// the NIO-SSH transport (which raises typed errors directly from the auth /
/// host-key delegates) so callers can pattern-match without caring which
/// transport produced the error.
public enum SSHTransportError: Error, Equatable, Sendable, LocalizedError {
    case hostUnreachable(String)
    case authFailed(String)
    /// Generic host-key verification failure as surfaced by system-ssh stderr.
    /// The NIO path uses `.hostKeyUnknown` / `.hostKeyMismatch` instead.
    case hostKeyVerification(String)
    case commandTimeout(String)
    case other(String)

    // Cases below are NIO-SSH–specific. They never appear from the
    // system-ssh stderr classifier — callers handling the system-ssh path
    // can ignore them.

    /// The presented identity is encrypted. **v1 limitation:** the in-tree
    /// OpenSSH key parser doesn't implement the bcrypt-KDF + aes256-ctr
    /// path yet, so re-invoking the transport factory with a passphrase
    /// will throw this same error. The host app should surface the
    /// documented workaround (`ssh-keygen -p -m OPENSSH -f <keyPath>
    /// -N ''` to decrypt offline, then re-add to the profile) or steer
    /// the user back to the system-ssh transport on macOS. The
    /// `keyPath` is the on-disk path the user pointed the profile at.
    case needsPassphrase(keyPath: String)
    /// First connection to a host whose key isn't in any trust store. The
    /// host app should show a TOFU confirm sheet displaying `fingerprint`
    /// and, on confirm, write to `PinnedHostKeyStore` before retrying.
    case hostKeyUnknown(fingerprint: String)
    /// A previously pinned host now presents a different key. Treat as a
    /// security alert; never silently re-pin.
    case hostKeyMismatch(presented: String, pinned: String)
    /// The user (or system policy) has explicitly revoked this host key
    /// via an OpenSSH `@revoked` `known_hosts` entry. Hard fail — the
    /// host app must refuse the connection and must not offer a re-pin
    /// flow, mirroring `/usr/bin/ssh`'s behavior.
    case hostKeyRevoked(fingerprint: String)
    /// Snapshot transfer over the NIO `cat` channel failed (non-zero exit,
    /// short read, oversize, etc.).
    case transferFailed(String)

    public var message: String {
        switch self {
        case let .hostUnreachable(message),
             let .authFailed(message),
             let .hostKeyVerification(message),
             let .commandTimeout(message),
             let .other(message),
             let .transferFailed(message):
            return message
        case let .needsPassphrase(keyPath):
            return "Key at \(keyPath) is encrypted and requires a passphrase."
        case let .hostKeyUnknown(fingerprint):
            return "Unknown host key (fingerprint \(fingerprint))."
        case let .hostKeyMismatch(presented, pinned):
            return "Host key mismatch — presented \(presented), pinned \(pinned)."
        case let .hostKeyRevoked(fingerprint):
            return "Host key \(fingerprint) is explicitly revoked."
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .hostUnreachable(message): return "Host unreachable: \(message)"
        case let .authFailed(message): return "Authentication failed: \(message)"
        case let .hostKeyVerification(message): return "Host key verification failed: \(message)"
        case let .commandTimeout(message): return "SSH timed out: \(message)"
        case let .other(message): return message
        case let .needsPassphrase(keyPath): return "Passphrase required for \(keyPath)"
        case let .hostKeyUnknown(fingerprint): return "Unknown host key (fingerprint \(fingerprint))"
        case let .hostKeyMismatch(presented, pinned):
            return "Host key mismatch — presented \(presented), pinned \(pinned)"
        case let .hostKeyRevoked(fingerprint):
            return "Host key revoked: \(fingerprint)"
        case let .transferFailed(message): return "Snapshot transfer failed: \(message)"
        }
    }
}

/// Stateless classifier for the stderr buffer the system-ssh binary emits.
/// Lives in its own file (without `#if os(macOS)`) so the NIO-SSH transport
/// can call into it from any Apple platform when the *remote* process — not
/// the SSH layer — emits a recognizable error line.
public enum SSHStderrClassifier {
    public static func classify(_ stderr: String) -> SSHTransportError {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .other("ssh exited without diagnostic output")
        }
        let lowered = trimmed.lowercased()
        if lowered.contains("host key verification failed") {
            return .hostKeyVerification(trimmed)
        }
        if lowered.contains("permission denied")
            || lowered.contains("publickey")
            || lowered.contains("no supported authentication methods") {
            return .authFailed(trimmed)
        }
        if lowered.contains("connection timed out")
            || lowered.contains("operation timed out") {
            return .commandTimeout(trimmed)
        }
        if lowered.contains("could not resolve hostname")
            || lowered.contains("name or service not known")
            || lowered.contains("no route to host")
            || lowered.contains("connection refused")
            || lowered.contains("network is unreachable") {
            return .hostUnreachable(trimmed)
        }
        return .other(trimmed)
    }
}
