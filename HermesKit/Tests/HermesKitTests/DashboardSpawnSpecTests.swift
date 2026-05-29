import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardSpawnSpecTests {
    @Test
    func localProfileSpawnsHermesDirectly() {
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "/opt/homebrew/bin/hermes")
        let spec = DashboardSpawnSpec.local(profile: profile, port: 46219)
        #expect(spec.executable.path == "/opt/homebrew/bin/hermes")
        #expect(spec.arguments == ["dashboard", "--no-open", "--host", "127.0.0.1", "--port", "46219"])
    }

    @Test
    func localProfileUsesBareNameWhenHermesPathIsNotAbsolute() {
        // When `hermesPath` is just `hermes` we shell out through `/usr/bin/env`
        // so the user's PATH resolution applies — mirrors how the ACP
        // `LocalProcessTransport` handles the same default.
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "hermes")
        let spec = DashboardSpawnSpec.local(profile: profile, port: 46219)
        #expect(spec.executable.path == "/usr/bin/env")
        #expect(spec.arguments.first == "hermes")
        #expect(spec.arguments.contains("dashboard"))
        #expect(spec.arguments.last == "46219")
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
        // space in "My Tools".
        #expect(command == "'/Users/x/My Tools/hermes' dashboard --no-open --host 127.0.0.1 --port 9119")
    }
}
