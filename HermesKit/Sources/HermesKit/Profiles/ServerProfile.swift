import Foundation

/// How a remote SSH session should invoke `hermes` on the target host. ssh's
/// default non-interactive command path does NOT source the user's shell rc
/// (zsh's `.zshrc`, bash's `.bashrc`) so anything the user added to `PATH`
/// there — including a Homebrew-installed `hermes` — isn't visible. Wrapping
/// the command in a login shell sources `.zprofile` / `.bash_profile`, which
/// typically do contain the PATH setup, fixing the common
/// "zsh:1: command not found: hermes" failure.
public enum RemoteShellMode: String, Codable, Sendable, CaseIterable {
    /// Run the command exactly as built. Fastest, but requires `hermes` to be
    /// on the non-interactive ssh PATH (absolute path, or `/etc/environment`
    /// / system-wide profile already covers it).
    case direct
    /// Wrap in `bash -lc '<cmd>'`. Sources `~/.bash_profile`, then `~/.bashrc`
    /// (on most setups). Most reliable default when bash is installed.
    case bashLogin
    /// Wrap in `zsh -lc '<cmd>'`. Sources `~/.zshenv` and `~/.zprofile`.
    /// Pick this when the remote login shell is zsh and the PATH lives in
    /// `~/.zshrc` (login mode pulls `.zprofile` but not `.zshrc` unless
    /// `-i` is also set — see `zshLoginInteractive`).
    case zshLogin
    /// Wrap in `zsh -ilc '<cmd>'`. Interactive *and* login — also sources
    /// `~/.zshrc`. Slower (per-call interactive startup) but rescues the
    /// case where PATH only exists in `.zshrc`.
    case zshLoginInteractive
    /// Wrap in `sh -lc '<cmd>'`. POSIX-only fallback for hosts without bash
    /// or zsh installed (alpine, BSDs without bash, etc.).
    case shLogin
    /// User-provided wrapper, joined with the command as `<prefix> '<cmd>'`.
    /// Useful when the user has a tool-version manager (mise, asdf, direnv)
    /// or container shim that needs a custom invocation.
    case custom

    public var label: String {
        switch self {
        case .direct: return "Direct (PATH must include hermes)"
        case .bashLogin: return "bash -lc (login shell)"
        case .zshLogin: return "zsh -lc (login shell)"
        case .zshLoginInteractive: return "zsh -ilc (interactive login shell)"
        case .shLogin: return "sh -lc (POSIX login shell)"
        case .custom: return "Custom prefix…"
        }
    }

    /// Wraps `command` (already a fully-built shell line — i.e. each token
    /// pre-quoted and space-joined) into the chosen invocation form. Returns
    /// the wrapped line as a single string, ready to be appended after the
    /// `--` separator on the ssh command line.
    public func wrap(command: String, customPrefix: String?) -> String {
        switch self {
        case .direct:
            return command
        case .bashLogin:
            return "bash -lc \(Self.singleQuote(command))"
        case .zshLogin:
            return "zsh -lc \(Self.singleQuote(command))"
        case .zshLoginInteractive:
            return "zsh -ilc \(Self.singleQuote(command))"
        case .shLogin:
            return "sh -lc \(Self.singleQuote(command))"
        case .custom:
            let prefix = (customPrefix ?? "").trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty else { return command }
            return "\(prefix) \(Self.singleQuote(command))"
        }
    }

    /// Wraps `value` in single quotes for safe inclusion inside another
    /// shell-quoted argument. Defined here (rather than reusing
    /// `SSHTransport.shellQuote`) so this module stays free of any
    /// transport-layer dependency.
    static func singleQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local
        case ssh
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var host: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var hermesPath: String
    public var hermesHome: String?
    public var env: [String: String]
    public var version: HermesVersion?
    public var remoteShellMode: RemoteShellMode
    public var remoteShellPrefix: String?
    /// Keychain item identifier for the SSH private key. Wired to the
    /// (future) iOS app's `KeychainIdentityProvider`. Optional on every
    /// platform — the macOS host today resolves identities from
    /// `identityFile` instead.
    public var keychainKeyReference: String?
    /// SHA256 fingerprint of the host key the user pinned via the TOFU
    /// confirm sheet. Stored here so the profile UI can surface "pinned"
    /// status without re-reading the host-key trust store. The trust store
    /// itself remains the source of truth for verification.
    public var pinnedHostKeyFingerprint: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        host: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        hermesPath: String = "hermes",
        hermesHome: String? = nil,
        env: [String: String] = [:],
        version: HermesVersion? = nil,
        remoteShellMode: RemoteShellMode = .shLogin,
        remoteShellPrefix: String? = nil,
        keychainKeyReference: String? = nil,
        pinnedHostKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.hermesPath = hermesPath
        self.hermesHome = hermesHome
        self.env = env
        self.version = version
        self.remoteShellMode = remoteShellMode
        self.remoteShellPrefix = remoteShellPrefix
        self.keychainKeyReference = keychainKeyReference
        self.pinnedHostKeyFingerprint = pinnedHostKeyFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, user, port, identityFile, hermesPath, hermesHome, env, version
        case remoteShellMode, remoteShellPrefix
        case keychainKeyReference, pinnedHostKeyFingerprint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.host = try c.decodeIfPresent(String.self, forKey: .host)
        self.user = try c.decodeIfPresent(String.self, forKey: .user)
        self.port = try c.decodeIfPresent(Int.self, forKey: .port)
        self.identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        self.hermesPath = try c.decodeIfPresent(String.self, forKey: .hermesPath) ?? "hermes"
        self.hermesHome = try c.decodeIfPresent(String.self, forKey: .hermesHome)
        self.env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        self.version = try c.decodeIfPresent(HermesVersion.self, forKey: .version)
        // Legacy profiles persisted before Sprint 5 didn't carry these keys.
        // The Sprint 4 probe already uses `sh -lc` and that's known to work
        // for these profiles (otherwise they couldn't have been saved), so
        // defaulting to `.shLogin` automatically heals the common
        // "zsh:1: command not found: hermes" failure when newer admin paths
        // run without a login wrapper. Users on hosts where the inverse is
        // true can still pick `.direct` in the editor.
        self.remoteShellMode = try c.decodeIfPresent(RemoteShellMode.self, forKey: .remoteShellMode) ?? .shLogin
        self.remoteShellPrefix = try c.decodeIfPresent(String.self, forKey: .remoteShellPrefix)
        self.keychainKeyReference = try c.decodeIfPresent(String.self, forKey: .keychainKeyReference)
        self.pinnedHostKeyFingerprint = try c.decodeIfPresent(String.self, forKey: .pinnedHostKeyFingerprint)
    }
}
