import Foundation

/// Shell-quoting helpers shared by every transport. They live outside any
/// `#if os(macOS)` gate so the NIO-SSH transport, the snapshot transfer and
/// the admin runners can all construct identical remote command lines on
/// every Apple platform.
public enum ShellQuoting {
    /// Wraps `value` in single quotes, escaping embedded single quotes with
    /// the standard `'\''` idiom. Use this for literal values where you do
    /// **not** want the remote shell to perform variable expansion.
    public static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Wraps `value` in double quotes, escaping the characters that double
    /// quotes don't otherwise neutralize (`\`, `"`, `` ` ``) but **leaving
    /// `$` alone** so the remote shell still expands `$HOME` and similar.
    /// Prefer ``shellQuote(_:)`` for literal values; reach for this only when
    /// you intentionally want variable expansion.
    public static func shellDoubleQuoteAllowingExpansion(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Builds the **fully wrapped** remote shell line that an SSH client should
/// append after the destination to launch `hermes acp` on the remote host.
///
/// The output is the final argv element handed to the underlying SSH client
/// (system-ssh appends it after `--`; the NIO-SSH transport sends it as the
/// command in `SSHChannelRequestEvent.ExecRequest`). Centralizing it here
/// guarantees both transports send byte-identical remote command lines, which
/// is what the regression test in `SSHTransportTests` locks in.
public func buildHermesRemoteCommand(
    hermesPath: String,
    hermesHome: String?,
    remoteShellMode: RemoteShellMode,
    remoteShellPrefix: String?
) -> String {
    var remoteParts: [String] = []
    if let hermesHome {
        remoteParts += ["env", ShellQuoting.shellQuote("HERMES_HOME=\(hermesHome)")]
    }
    remoteParts += [ShellQuoting.shellQuote(hermesPath), "acp"]
    let inner = remoteParts.joined(separator: " ")
    return remoteShellMode.wrap(command: inner, customPrefix: remoteShellPrefix)
}

/// Convenience overload that pulls the remote-command knobs straight off a
/// ``ServerProfile``. Both transports use this so the wrapped command stays
/// identical across the system-ssh and NIO-SSH paths.
public func buildHermesRemoteCommand(profile: ServerProfile) -> String {
    buildHermesRemoteCommand(
        hermesPath: profile.hermesPath,
        hermesHome: profile.hermesHome,
        remoteShellMode: profile.remoteShellMode,
        remoteShellPrefix: profile.remoteShellPrefix
    )
}
