import Foundation

/// Everything an embedded terminal emulator needs to spawn a Hermes TUI as a
/// local PTY process. Unlike the ACP path (`Transport`/`Client`), a TUI
/// "session" bypasses the protocol stack entirely: the app hands this spec to
/// SwiftTerm's `LocalProcessTerminalView`, which forks the process under a PTY
/// and renders its raw terminal output.
///
/// The struct is UI-free and lives in HermesKit so the command/env assembly
/// stays pure and testable; the SwiftTerm view that consumes it is a
/// macOS-only app seam.
///
/// - For a **local** profile the executable is `/usr/bin/env` (or a login
///   shell wrapper) running `hermes chat --tui`.
/// - For a **remote** profile the executable is `/usr/bin/ssh` with `-tt` (a
///   PTY allocation) and the wrapped remote command from
///   ``buildHermesTUIRemoteCommand(hermesPath:hermesHome:remoteShellMode:remoteShellPrefix:hermesProfileName:resume:)``
///   as its trailing argv element.
public struct TUILaunchSpec: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var cwd: String?

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        cwd: String? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.cwd = cwd
    }
}

/// Builds the **fully wrapped** remote shell line that an SSH client appends
/// after the destination to launch `hermes chat --tui` on the remote host.
///
/// Mirrors ``buildHermesRemoteCommand(hermesPath:hermesHome:remoteShellMode:remoteShellPrefix:hermesProfileName:)``
/// (the ACP equivalent) byte-for-byte except for the subcommand: it emits
/// `chat --tui` (plus `-r <id>` when resuming) instead of `acp`. Centralizing
/// it here keeps the remote command shape under the same regression coverage
/// as the ACP path. The caller embeds the returned string as the trailing argv
/// element of an `ssh -tt … -- <destination>` invocation.
public func buildHermesTUIRemoteCommand(
    hermesPath: String,
    hermesHome: String?,
    remoteShellMode: RemoteShellMode,
    remoteShellPrefix: String?,
    hermesProfileName: String? = nil,
    resume: SessionId? = nil
) -> String {
    var remoteParts: [String] = []
    if let hermesHome {
        remoteParts += ["env", ShellQuoting.shellQuote("HERMES_HOME=\(hermesHome)")]
    }
    // `-p <name>` is a global flag: it goes between the binary and the `chat`
    // subcommand, and collapses to nothing for the default profile.
    remoteParts += [ShellQuoting.shellQuote(hermesPath)]
    remoteParts += HermesProfiles.remoteCLIFlag(hermesProfileName)
    remoteParts += ["chat", "--tui"]
    // `-r <id>` resumes an existing session; omitted for a fresh chat.
    if let resume, !resume.isEmpty {
        remoteParts += ["-r", ShellQuoting.shellQuote(resume)]
    }
    let inner = remoteParts.joined(separator: " ")
    return remoteShellMode.wrap(command: inner, customPrefix: remoteShellPrefix)
}

/// Convenience overload that pulls the remote-command knobs straight off a
/// ``ServerProfile``, matching the ACP ``buildHermesRemoteCommand(profile:hermesProfileName:)``.
public func buildHermesTUIRemoteCommand(
    profile: ServerProfile,
    hermesProfileName: String? = nil,
    resume: SessionId? = nil
) -> String {
    buildHermesTUIRemoteCommand(
        hermesPath: profile.hermesPath,
        hermesHome: profile.hermesHome,
        remoteShellMode: profile.remoteShellMode,
        remoteShellPrefix: profile.remoteShellPrefix,
        hermesProfileName: hermesProfileName,
        resume: resume
    )
}
