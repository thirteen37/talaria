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

    // MARK: - Heartbeat-pipe watchdog

    /// A POSIX `/bin/sh` watchdog that ties the spawned dashboard's lifetime to
    /// a **heartbeat pipe** held open on the watchdog's stdin. The app holds the
    /// only write end of that pipe; on *any* app death — graceful quit, crash,
    /// or `kill -9` — the kernel closes the app's end and the watchdog's read of
    /// stdin reaches EOF, at which point it kills the dashboard. This is the one
    /// mechanism that works even when no app code runs at death time (a crash),
    /// which `applicationWillTerminate` / `.onDisappear` teardown cannot cover.
    ///
    /// Contract (run via `sh -c <script> sh <argv…>`, heartbeat arrives on fd 0):
    /// - `exec 3<&0` stashes the heartbeat on fd 3 **before** anything is
    ///   backgrounded. This is load-bearing: POSIX sh reassigns a background
    ///   job's stdin to `/dev/null` ("before any explicit redirections"), so a
    ///   reaper that read plain fd 0 would see instant EOF and kill the
    ///   dashboard immediately. Reading the heartbeat via the explicit `<&3`
    ///   redirect is what makes the reaper actually block until app death.
    /// - `term()` escalates: SIGTERM, then SIGKILL after a ~2s grace if the
    ///   dashboard is still alive. The watchdog holds the only reliable handle
    ///   to the dashboard PID (it reparents away from the app on the app's
    ///   death), so the watchdog — not the app — must own the hard kill;
    ///   otherwise a dashboard that ignores SIGTERM leaks, the failure this
    ///   whole mechanism exists to prevent. The grace uses integer `sleep 1`
    ///   (POSIX only guarantees integer seconds — fractional `sleep 0.2` errors
    ///   out instantly on strict-POSIX hosts like AIX, collapsing the grace
    ///   window and hard-killing a hermes still flushing on SIGTERM).
    /// - run `command` with its stdin detached from the heartbeat (`0</dev/null`,
    ///   `3<&-`) so the dashboard neither consumes nor holds the heartbeat;
    /// - a background reaper blocks reading the heartbeat (`<&3`) and escalates a
    ///   kill of the dashboard on EOF (app death);
    /// - the EXIT trap escalates the kill of the dashboard and reaps the reaper.
    ///   On the `TERM`/`INT` path (in-session `Process.terminate`) this is where
    ///   the dashboard actually gets killed; on self-exit `term` is a no-op since
    ///   `wait` already returned.
    /// - `wait` on the dashboard returns its real status on self-exit, so the app
    ///   still detects a dashboard crash via the exit code.
    static func watchdogScript(running command: String) -> String {
        "exec 3<&0; term() { kill \"$1\" 2>/dev/null; i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); if [ \"$i\" -ge 3 ]; then kill -9 \"$1\" 2>/dev/null; return; fi; sleep 1; done; }; \(command) 0</dev/null 3<&- & c=$!; trap 'term \"$c\"; kill \"$r\" 2>/dev/null' EXIT; trap 'exit 143' TERM INT; ( while IFS= read -r _; do :; done; term \"$c\" ) <&3 & r=$!; wait \"$c\"; s=$?; exit \"$s\""
    }

    /// Wraps the dashboard command in the watchdog and then in whatever remote
    /// shell the profile selects — **forcing a POSIX `sh` for the `.direct`
    /// mode**. `.direct` hands the command straight to the user's login shell
    /// (which may be csh/tcsh/fish), none of which can parse the POSIX watchdog;
    /// running it under `sh -c` means the login shell only has to parse the
    /// simple `sh -c '<script>'` token. The login-shell modes (`sh -lc`,
    /// `bash -lc`, `zsh -lc`, …) already invoke a POSIX-compatible shell, so the
    /// watchdog runs fine under them unchanged.
    static func wrapRemoteWatchdog(dashboardLine: String, profile: ServerProfile) -> String {
        let watched = watchdogScript(running: dashboardLine)
        if profile.remoteShellMode == .direct {
            return "sh -c \(ShellQuoting.shellQuote(watched))"
        }
        return profile.remoteShellMode.wrap(command: watched, customPrefix: profile.remoteShellPrefix)
    }

    /// Watchdog for the local launcher: the real argv is passed positionally
    /// after `sh` (consumed by `"$@"`), which sidesteps every quoting problem
    /// and works for both the absolute-path and `/usr/bin/env hermes` forms.
    static let localWatchdogScript = watchdogScript(running: "\"$@\"")

    /// Spec for spawning the dashboard on the same host as Talaria. Mirrors
    /// `LocalProcessTransport`'s handling of a bare `hermes` path: when it
    /// isn't absolute, we shell out through `/usr/bin/env` so the user's
    /// PATH (and any Homebrew shim) is consulted.
    public static func local(
        profile: ServerProfile,
        port: Int,
        hermesProfileName: String? = nil
    ) -> DashboardSpawnSpec {
        let dashboardArgs = HermesProfiles.cliFlag(hermesProfileName)
            + ["dashboard", "--no-open", "--host", "127.0.0.1", "--port", String(port)]
        var environment = profile.env
        if let home = profile.hermesHome, !home.isEmpty {
            environment["HERMES_HOME"] = home
        }
        let hermesPath = profile.hermesPath
        let hermesArgv: [String]
        if hermesPath.hasPrefix("/") {
            hermesArgv = [hermesPath] + dashboardArgs
        } else {
            // Bare name: shell out through `/usr/bin/env` so PATH resolution
            // (Homebrew shim) applies, mirroring `LocalProcessTransport`.
            hermesArgv = ["/usr/bin/env", hermesPath] + dashboardArgs
        }
        // Run the dashboard under the heartbeat-pipe watchdog so it dies with
        // the app even on crash/SIGKILL. `hermesArgv` is passed positionally so
        // `"$@"` reconstructs it verbatim — no re-quoting needed.
        return DashboardSpawnSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", localWatchdogScript, "sh"] + hermesArgv,
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
        remotePort: Int,
        hermesProfileName: String? = nil
    ) -> DashboardSpawnSpec {
        // Single-quote the binary path so a hermes install at a path with
        // whitespace or shell metacharacters (e.g. `/Users/x/My Tools/hermes`)
        // survives the remote shell's word splitting. `RemoteShellMode.wrap`
        // re-quotes the whole line for the chosen login shell on top of this.
        var remoteParts: [String] = []
        if let hermesHome = profile.hermesHome, !hermesHome.isEmpty {
            remoteParts += ["env", ShellQuoting.shellQuote("HERMES_HOME=\(hermesHome)")]
        }
        remoteParts += [ShellQuoting.shellQuote(profile.hermesPath)]
        remoteParts += HermesProfiles.remoteCLIFlag(hermesProfileName)
        remoteParts += [
            "dashboard",
            "--no-open",
            "--host",
            "127.0.0.1",
            "--port",
            String(remotePort),
        ]
        let dashboardLine = remoteParts.joined(separator: " ")
        // Wrap the remote hermes invocation in the same watchdog, with the
        // heartbeat being the **remote stdin** (the SSH channel). When the
        // channel closes — app death, local `ssh` exit, or dropped connection —
        // remote stdin EOFs and the remote watchdog kills hermes.
        let wrapped = Self.wrapRemoteWatchdog(dashboardLine: dashboardLine, profile: profile)

        var arguments: [String] = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            // Detect an abrupt client death within seconds so the channel closes
            // (tripping the remote watchdog) rather than lingering on TCP timeout.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
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

    /// Spec for spawning the dashboard on a remote SSH host over the pure-Swift
    /// NIO-SSH transport (iOS, where `/usr/bin/ssh` and `Process` don't exist).
    /// Unlike ``remote(profile:localPort:remotePort:)`` there's no `ssh -L`
    /// wrapper and no local port: the NIO launcher execs `arguments[0]`
    /// directly on a session channel, and HTTP reaches the dashboard through a
    /// `direct-tcpip` channel to `127.0.0.1:<port>` rather than a local
    /// forward. `executable` is a sentinel the NIO launcher ignores.
    public static func remoteNIO(
        profile: ServerProfile,
        port: Int,
        hermesProfileName: String? = nil
    ) -> DashboardSpawnSpec {
        var remoteParts: [String] = []
        if let hermesHome = profile.hermesHome, !hermesHome.isEmpty {
            remoteParts += ["env", ShellQuoting.shellQuote("HERMES_HOME=\(hermesHome)")]
        }
        remoteParts += [ShellQuoting.shellQuote(profile.hermesPath)]
        remoteParts += HermesProfiles.remoteCLIFlag(hermesProfileName)
        remoteParts += [
            "dashboard",
            "--no-open",
            "--host",
            "127.0.0.1",
            "--port",
            String(port),
        ]
        let dashboardLine = remoteParts.joined(separator: " ")
        // Same watchdog as the system-ssh path: the heartbeat is the remote
        // stdin carried by the NIO exec channel, so closing that channel (in
        // `NIOSSHDashboardConnection.terminate()` or on socket drop / app death)
        // EOFs remote stdin and the remote watchdog kills hermes.
        let wrapped = Self.wrapRemoteWatchdog(dashboardLine: dashboardLine, profile: profile)
        return DashboardSpawnSpec(
            executable: URL(fileURLWithPath: "/nio-ssh"),
            arguments: [wrapped],
            environment: [:]
        )
    }
}
