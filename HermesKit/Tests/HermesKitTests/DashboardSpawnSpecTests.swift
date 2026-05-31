import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardSpawnSpecTests {
    /// Expected `.direct`-mode remote command: the watchdog (wrapping `inner`)
    /// run under an explicit POSIX `sh -c`, since `.direct` would otherwise hand
    /// the POSIX watchdog straight to a possibly-csh/fish login shell.
    private func directWatchdogCommand(_ inner: String) -> String {
        "sh -c " + ShellQuoting.shellQuote(DashboardSpawnSpec.watchdogScript(running: inner))
    }

    @Test
    func localProfileSpawnsHermesUnderWatchdog() {
        // The dashboard is spawned under the `/bin/sh` heartbeat watchdog; the
        // real argv is passed positionally after `sh` so `"$@"` reconstructs it.
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "/opt/homebrew/bin/hermes")
        let spec = DashboardSpawnSpec.local(profile: profile, port: 46219)
        #expect(spec.executable.path == "/bin/sh")
        #expect(spec.arguments == [
            "-c", DashboardSpawnSpec.localWatchdogScript, "sh",
            "/opt/homebrew/bin/hermes", "dashboard", "--no-open", "--host", "127.0.0.1", "--port", "46219",
        ])
    }

    @Test
    func localProfileUsesBareNameWhenHermesPathIsNotAbsolute() {
        // When `hermesPath` is just `hermes` we shell out through `/usr/bin/env`
        // so the user's PATH resolution applies — mirrors how the ACP
        // `LocalProcessTransport` handles the same default. The `/usr/bin/env`
        // form is preserved verbatim inside the watchdog's positional argv.
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "hermes")
        let spec = DashboardSpawnSpec.local(profile: profile, port: 46219)
        #expect(spec.executable.path == "/bin/sh")
        #expect(spec.arguments == [
            "-c", DashboardSpawnSpec.localWatchdogScript, "sh",
            "/usr/bin/env", "hermes", "dashboard", "--no-open", "--host", "127.0.0.1", "--port", "46219",
        ])
    }

    @Test
    func localProfileForwardsHermesHomeEnvironmentWhenSet() {
        var profile = ServerProfile(name: "Local", kind: .local, hermesPath: "/opt/homebrew/bin/hermes")
        profile.hermesHome = "/tmp/alt-home"
        let spec = DashboardSpawnSpec.local(profile: profile, port: 9000)
        #expect(spec.environment["HERMES_HOME"] == "/tmp/alt-home")
    }

    @Test
    func remoteProfileBuildsSSHCommandWithPortForward() throws {
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "hermes.local",
            user: "yuxi",
            port: 2222,
            identityFile: "/Users/yuxi/.ssh/id_ed25519",
            hermesPath: "hermes",
            remoteShellMode: .shLogin
        )
        let spec = DashboardSpawnSpec.remote(profile: profile, localPort: 51919, remotePort: 9119)
        #expect(spec.executable.path == "/usr/bin/ssh")
        // Standard SSH boilerplate is preserved.
        #expect(spec.arguments.contains("-T"))
        #expect(spec.arguments.contains("BatchMode=yes"))
        // Keepalives so an abrupt client death closes the channel promptly,
        // tripping the remote watchdog rather than waiting on TCP timeout.
        #expect(spec.arguments.contains("ServerAliveInterval=5"))
        #expect(spec.arguments.contains("ServerAliveCountMax=3"))
        // Port-forward must reference the loopback bind on the *remote*.
        let idx = try #require(spec.arguments.firstIndex(of: "-L"))
        #expect(spec.arguments[idx + 1] == "51919:127.0.0.1:9119")
        // Identity and port flags are forwarded.
        #expect(spec.arguments.contains("/Users/yuxi/.ssh/id_ed25519"))
        let pIndex = try #require(spec.arguments.firstIndex(of: "-p"))
        #expect(spec.arguments[pIndex + 1] == "2222")
        // Destination is `user@host` and appears just before the remote
        // command on the SSH command line.
        #expect(spec.arguments.contains("yuxi@hermes.local"))
        // The remote command runs under `sh -lc` so the user's PATH is
        // picked up before `hermes` resolves.
        let command = try #require(spec.arguments.last)
        #expect(command.hasPrefix("sh -lc"))
        #expect(command.contains("dashboard --no-open --host 127.0.0.1 --port 9119"))
        // …and under the heartbeat watchdog so the remote hermes dies when the
        // SSH channel (remote stdin) closes.
        #expect(command.contains("while IFS= read"))
    }

    @Test
    func directModeRunsWatchdogUnderPOSIXShellButLoginModesDoNot() throws {
        // `.direct` would otherwise hand the POSIX watchdog straight to the
        // user's login shell (csh/tcsh/fish can't parse it), so it must be run
        // under an explicit `sh -c`. Login-shell modes already invoke a
        // POSIX-compatible shell and must NOT get a redundant `sh -c` prefix.
        var direct = ServerProfile(name: "Box", kind: .ssh, host: "h", hermesPath: "hermes", remoteShellMode: .direct)
        direct.user = "x"
        let directCmd = try #require(DashboardSpawnSpec.remote(profile: direct, localPort: 1, remotePort: 2).arguments.last)
        #expect(directCmd.hasPrefix("sh -c '"))
        #expect(directCmd.contains("while IFS= read"))

        var login = ServerProfile(name: "Box", kind: .ssh, host: "h", hermesPath: "hermes", remoteShellMode: .shLogin)
        login.user = "x"
        let loginCmd = try #require(DashboardSpawnSpec.remote(profile: login, localPort: 1, remotePort: 2).arguments.last)
        #expect(loginCmd.hasPrefix("sh -lc "))
        #expect(!loginCmd.hasPrefix("sh -c '"))
    }

    @Test
    func remoteProfileRespectsZshLoginInteractiveShellMode() throws {
        var profile = ServerProfile(name: "Box", kind: .ssh, host: "h", remoteShellMode: .zshLoginInteractive)
        profile.user = "x"
        let spec = DashboardSpawnSpec.remote(profile: profile, localPort: 1000, remotePort: 9119)
        let command = try #require(spec.arguments.last)
        #expect(command.hasPrefix("zsh -ilc"))
    }

    @Test
    func remoteProfileQuotesHermesPathWithWhitespace() throws {
        // `.direct` mode skips the login-shell wrapper that would re-quote the
        // whole line, so the binary-path quoting is directly observable.
        var profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "h",
            hermesPath: "/Users/x/My Tools/hermes",
            remoteShellMode: .direct
        )
        profile.user = "x"
        let spec = DashboardSpawnSpec.remote(profile: profile, localPort: 1000, remotePort: 9119)
        let command = try #require(spec.arguments.last)
        // The path must be quoted so the remote shell doesn't split it at the
        // space in "My Tools". `.direct` mode skips the login-shell wrapper, so
        // the watchdog is run under an explicit `sh -c`.
        #expect(command == directWatchdogCommand(
            "'/Users/x/My Tools/hermes' dashboard --no-open --host 127.0.0.1 --port 9119"
        ))
    }

    // MARK: - Profile scoping (-p <name>)

    @Test
    func localProfileInsertsProfileFlagBeforeDashboard() {
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "/opt/homebrew/bin/hermes")
        let spec = DashboardSpawnSpec.local(profile: profile, port: 9000, hermesProfileName: "work")
        // `-p work` is a global flag and must precede the `dashboard` subcommand.
        #expect(spec.arguments == [
            "-c", DashboardSpawnSpec.localWatchdogScript, "sh",
            "/opt/homebrew/bin/hermes", "-p", "work", "dashboard", "--no-open", "--host", "127.0.0.1", "--port", "9000",
        ])
    }

    @Test
    func localProfileInsertsProfileFlagAfterBareHermesName() {
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "hermes")
        let spec = DashboardSpawnSpec.local(profile: profile, port: 9000, hermesProfileName: "work")
        #expect(spec.executable.path == "/bin/sh")
        #expect(spec.arguments == [
            "-c", DashboardSpawnSpec.localWatchdogScript, "sh",
            "/usr/bin/env", "hermes", "-p", "work", "dashboard", "--no-open", "--host", "127.0.0.1", "--port", "9000",
        ])
    }

    @Test
    func localProfileOmitsProfileFlagForDefaultOrNil() {
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "/opt/homebrew/bin/hermes")
        let base = [
            "-c", DashboardSpawnSpec.localWatchdogScript, "sh",
            "/opt/homebrew/bin/hermes", "dashboard", "--no-open", "--host", "127.0.0.1", "--port", "9000",
        ]
        // `default` == no `-p` (the window's shared dashboard already serves it).
        #expect(DashboardSpawnSpec.local(profile: profile, port: 9000, hermesProfileName: "default").arguments == base)
        #expect(DashboardSpawnSpec.local(profile: profile, port: 9000, hermesProfileName: nil).arguments == base)
    }

    @Test
    func remoteProfileInsertsProfileFlagBeforeDashboard() throws {
        var profile = ServerProfile(name: "Box", kind: .ssh, host: "h", hermesPath: "hermes", remoteShellMode: .direct)
        profile.user = "x"
        let spec = DashboardSpawnSpec.remote(profile: profile, localPort: 1000, remotePort: 9119, hermesProfileName: "work")
        let command = try #require(spec.arguments.last)
        #expect(command == directWatchdogCommand(
            "'hermes' -p 'work' dashboard --no-open --host 127.0.0.1 --port 9119"
        ))
    }

    @Test
    func remoteProfileOmitsProfileFlagForDefault() throws {
        var profile = ServerProfile(name: "Box", kind: .ssh, host: "h", hermesPath: "hermes", remoteShellMode: .direct)
        profile.user = "x"
        let spec = DashboardSpawnSpec.remote(profile: profile, localPort: 1000, remotePort: 9119, hermesProfileName: "default")
        let command = try #require(spec.arguments.last)
        #expect(command == directWatchdogCommand(
            "'hermes' dashboard --no-open --host 127.0.0.1 --port 9119"
        ))
    }

    @Test
    func remoteNIOProfileInsertsProfileFlagBeforeDashboard() throws {
        var profile = ServerProfile(name: "Box", kind: .ssh, host: "h", hermesPath: "hermes", remoteShellMode: .direct)
        profile.user = "x"
        let spec = DashboardSpawnSpec.remoteNIO(profile: profile, port: 9119, hermesProfileName: "work")
        let command = try #require(spec.arguments.last)
        #expect(command == directWatchdogCommand(
            "'hermes' -p 'work' dashboard --no-open --host 127.0.0.1 --port 9119"
        ))
    }

    @Test
    func remoteNIOProfileOmitsProfileFlagForNil() throws {
        var profile = ServerProfile(name: "Box", kind: .ssh, host: "h", hermesPath: "hermes", remoteShellMode: .direct)
        profile.user = "x"
        let spec = DashboardSpawnSpec.remoteNIO(profile: profile, port: 9119, hermesProfileName: nil)
        let command = try #require(spec.arguments.last)
        #expect(command == directWatchdogCommand(
            "'hermes' dashboard --no-open --host 127.0.0.1 --port 9119"
        ))
    }

    @Test
    func remoteProfileForwardsHermesHomeEnvironmentWhenSet() throws {
        var profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "h",
            hermesPath: "hermes",
            hermesHome: "/Users/x/Alt Hermes",
            remoteShellMode: .direct
        )
        profile.user = "x"
        let spec = DashboardSpawnSpec.remote(profile: profile, localPort: 1000, remotePort: 9119)
        let command = try #require(spec.arguments.last)
        #expect(command == directWatchdogCommand(
            "env 'HERMES_HOME=/Users/x/Alt Hermes' 'hermes' dashboard --no-open --host 127.0.0.1 --port 9119"
        ))
    }
}
