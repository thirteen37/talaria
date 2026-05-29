import Foundation

/// Command-line shape for spawning `hermes dashboard`, with the SSH
/// port-forward wrapper for remote profiles. Pure value type — built by the
/// supervisor, handed to a `DashboardProcessLauncher`. Kept separate from
/// the launcher so the command-construction logic stays trivially testable
/// without standing up real processes.
public struct DashboardSpawnSpec: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// Spec for spawning the dashboard on the same host as Talaria. Mirrors
    /// `LocalProcessTransport`'s handling of a bare `hermes` path: when it
    /// isn't absolute, we shell out through `/usr/bin/env` so the user's
    /// PATH (and any Homebrew shim) is consulted.
    public static func local(profile: ServerProfile, port: Int) -> DashboardSpawnSpec {
        let dashboardArgs = ["dashboard", "--no-open", "--host", "127.0.0.1", "--port", String(port)]
        var environment = profile.env
        if let home = profile.hermesHome, !home.isEmpty {
            environment["HERMES_HOME"] = home
        }
        let hermesPath = profile.hermesPath
        if hermesPath.hasPrefix("/") {
            return DashboardSpawnSpec(
                executable: URL(fileURLWithPath: hermesPath),
                arguments: dashboardArgs,
                environment: environment
            )
        }
        return DashboardSpawnSpec(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [hermesPath] + dashboardArgs,
            environment: environment
        )
    }

    /// Spec for spawning the dashboard on a remote SSH host with a loopback
    /// port-forward back to Talaria. Composes the dashboard invocation
    /// (wrapped by `profile.remoteShellMode` so the remote PATH resolves
    /// the user's `hermes` install) with the SSH boilerplate also used by
    /// `RemoteSnapshot` — `BatchMode`, `ConnectTimeout`, identity file,
    /// custom port — plus a `-L <local>:127.0.0.1:<remote>` forward.
    public static func remote(
        profile: ServerProfile,
        localPort: Int,
        remotePort: Int
    ) -> DashboardSpawnSpec {
        // Single-quote the binary path so a hermes install at a path with
        // whitespace or shell metacharacters (e.g. `/Users/x/My Tools/hermes`)
        // survives the remote shell's word splitting. `RemoteShellMode.wrap`
        // re-quotes the whole line for the chosen login shell on top of this.
        var remoteParts: [String] = []
        if let hermesHome = profile.hermesHome, !hermesHome.isEmpty {
            remoteParts += ["env", ShellQuoting.shellQuote("HERMES_HOME=\(hermesHome)")]
        }
        remoteParts += [
            ShellQuoting.shellQuote(profile.hermesPath),
            "dashboard",
            "--no-open",
            "--host",
            "127.0.0.1",
            "--port",
            String(remotePort),
        ]
        let dashboardLine = remoteParts.joined(separator: " ")
        let wrapped = profile.remoteShellMode.wrap(
            command: dashboardLine,
            customPrefix: profile.remoteShellPrefix
        )

        var arguments: [String] = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
        ]
        if let port = profile.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = profile.identityFile, !identityFile.isEmpty {
            arguments += ["-i", identityFile]
        }
        let host = profile.host ?? ""
        let destination = profile.user.map { "\($0)@\(host)" } ?? host
        arguments += ["--", destination, wrapped]

        return DashboardSpawnSpec(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            environment: [:]
        )
    }
}
