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
    remoteShellPrefix: String?,
    hermesProfileName: String? = nil
) -> String {
    var remoteParts: [String] = []
    if let hermesHome {
        remoteParts += ["env", ShellQuoting.shellQuote("HERMES_HOME=\(hermesHome)")]
    }
    // `-p <name>` is a global flag: it goes between the binary and the `acp`
    // subcommand, and collapses to nothing for the default profile.
    remoteParts += [ShellQuoting.shellQuote(hermesPath)]
    remoteParts += HermesProfiles.remoteCLIFlag(hermesProfileName)
    remoteParts += ["acp"]
    let inner = remoteParts.joined(separator: " ")
    return remoteShellMode.wrap(command: inner, customPrefix: remoteShellPrefix)
}

/// Convenience overload that pulls the remote-command knobs straight off a
/// ``ServerProfile``. Both transports use this so the wrapped command stays
/// identical across the system-ssh and NIO-SSH paths.
public func buildHermesRemoteCommand(profile: ServerProfile, hermesProfileName: String? = nil) -> String {
    buildHermesRemoteCommand(
        hermesPath: profile.hermesPath,
        hermesHome: profile.hermesHome,
        remoteShellMode: profile.remoteShellMode,
        remoteShellPrefix: profile.remoteShellPrefix,
        hermesProfileName: hermesProfileName
    )
}

/// Builds the **fully wrapped** remote shell line that launches a `hermes`
/// *admin* subcommand (`sessions`, `doctor`, `tools`, …) over SSH. This is the
/// single source of truth shared by the system-ssh `RemoteHermesAdminRunner`
/// (macOS) and the `#if`-free `NIOSSHHermesAdminRunner`, so both transports
/// send byte-identical command lines.
///
/// The shape is `env COLUMNS=400 [HERMES_HOME=…] <hermesPath> <args…>` then
/// run through the profile's shell wrapper. `COLUMNS=400` is always set: Rich
/// on the remote falls back to an 80-col layout under non-interactive ssh,
/// which truncates table cells (skill names, tool descriptions) into
/// ellipsis-suffixed strings the parsers can't recover from. Folding COLUMNS
/// into the same env prefix `HERMES_HOME` uses keeps the quoting in one place.
public func buildHermesAdminRemoteCommand(
    hermesPath: String,
    hermesHome: String?,
    arguments: [String],
    remoteShellMode: RemoteShellMode,
    remoteShellPrefix: String?
) -> String {
    var envAssignments: [String] = ["COLUMNS=400"]
    if let hermesHome, !hermesHome.isEmpty {
        envAssignments.append("HERMES_HOME=\(hermesHome)")
    }
    var remoteParts: [String] = ["env"]
    remoteParts += envAssignments.map { ShellQuoting.shellQuote($0) }
    remoteParts.append(ShellQuoting.shellQuote(hermesPath))
    remoteParts += arguments.map { ShellQuoting.shellQuote($0) }
    let inner = remoteParts.joined(separator: " ")
    return remoteShellMode.wrap(command: inner, customPrefix: remoteShellPrefix)
}

/// Convenience overload that pulls the admin-command knobs off a
/// ``ServerProfile`` and a ``HermesAdminCommand``.
public func buildHermesAdminRemoteCommand(profile: ServerProfile, command: HermesAdminCommand) -> String {
    buildHermesAdminRemoteCommand(
        hermesPath: profile.hermesPath,
        hermesHome: profile.hermesHome,
        arguments: command.arguments,
        remoteShellMode: profile.remoteShellMode,
        remoteShellPrefix: profile.remoteShellPrefix
    )
}

/// Returns the shell expression that, when evaluated by the remote shell,
/// resolves to the Hermes home directory the Logs view should tail. The
/// returned string is meant to be embedded inside a double-quoted shell
/// argument so `$HOME` (and the `${HERMES_HOME:-…}` default form) get
/// expanded at run time on the remote host.
///
/// - No explicit value -> `${HERMES_HOME:-$HOME/.hermes}` (matches the
///   default hermes itself uses when the env var is unset).
/// - Absolute path -> returned unchanged.
/// - `~` / `~/…` -> rewritten to `$HOME` / `$HOME/…` so the remote shell
///   does the expansion; local `~` expansion would use the wrong user's
///   home for SSH profiles.
public func remoteHermesHomeExpression(hermesHome: String?) -> String {
    guard let value = hermesHome?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
        return "${HERMES_HOME:-$HOME/.hermes}"
    }
    if value == "~" { return "$HOME" }
    if value.hasPrefix("~/") {
        return "$HOME/\(String(value.dropFirst(2)))"
    }
    return value
}

/// Builds the wrapped remote command that prints the resolved Hermes home
/// path to stdout when invoked over SSH. Wrapped through the profile's
/// `remoteShellMode` so login shells get a chance to seed `HERMES_HOME` from
/// rc files; output is a single newline-terminated path.
public func buildRemoteHermesHomeResolveCommand(
    hermesHome: String?,
    remoteShellMode: RemoteShellMode,
    remoteShellPrefix: String?
) -> String {
    let expression = remoteHermesHomeExpression(hermesHome: hermesHome)
    let inner = "printf '%s\\n' \(ShellQuoting.shellDoubleQuoteAllowingExpansion(expression))"
    return remoteShellMode.wrap(command: inner, customPrefix: remoteShellPrefix)
}
