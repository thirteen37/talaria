import Foundation
import Testing
@testable import HermesKit

@Suite
struct RemoteShellInvocationTests {
    @Test
    func directModeAppendsBareCommand() {
        let line = buildHermesRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .direct,
            remoteShellPrefix: nil
        )
        #expect(line == "'hermes' acp")
    }

    @Test
    func bashLoginWraps() {
        let line = buildHermesRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .bashLogin,
            remoteShellPrefix: nil
        )
        #expect(line == "bash -lc ''\\''hermes'\\'' acp'")
    }

    @Test
    func hermesHomePrependsEnv() {
        let line = buildHermesRemoteCommand(
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes",
            remoteShellMode: .direct,
            remoteShellPrefix: nil
        )
        #expect(line == "env 'HERMES_HOME=/tmp/hermes' '/opt/bin/hermes' acp")
    }

    @Test
    func customPrefixWraps() {
        let line = buildHermesRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .custom,
            remoteShellPrefix: "mise exec --"
        )
        #expect(line == "mise exec -- ''\\''hermes'\\'' acp'")
    }

    @Test
    func profileOverloadMatchesFieldOverload() {
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "example.com",
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes",
            remoteShellMode: .bashLogin
        )
        let fromProfile = buildHermesRemoteCommand(profile: profile)
        let fromFields = buildHermesRemoteCommand(
            hermesPath: profile.hermesPath,
            hermesHome: profile.hermesHome,
            remoteShellMode: profile.remoteShellMode,
            remoteShellPrefix: profile.remoteShellPrefix
        )
        #expect(fromProfile == fromFields)
    }

    @Test
    func remoteHermesHomeExpressionDefaultsToHermesConvention() {
        // No explicit value: the expression must resolve like hermes itself
        // does, preferring an exported `HERMES_HOME` and falling back to
        // `$HOME/.hermes`. Letting the remote shell expand `${X:-Y}` means
        // the Logs view sees the same path the hermes daemon writes to.
        #expect(remoteHermesHomeExpression(hermesHome: nil) == "${HERMES_HOME:-$HOME/.hermes}")
        #expect(remoteHermesHomeExpression(hermesHome: "") == "${HERMES_HOME:-$HOME/.hermes}")
        #expect(remoteHermesHomeExpression(hermesHome: "   ") == "${HERMES_HOME:-$HOME/.hermes}")
    }

    @Test
    func remoteHermesHomeExpressionPassesAbsolutePathsThrough() {
        // An absolute path is what the user typed; we don't second-guess it.
        // Returning it unchanged means the resolve probe (and the tail
        // script) both see the literal path and don't try to expand it
        // again on the remote.
        #expect(remoteHermesHomeExpression(hermesHome: "/var/hermes") == "/var/hermes")
        #expect(remoteHermesHomeExpression(hermesHome: "/opt/data/hermes") == "/opt/data/hermes")
    }

    @Test
    func remoteHermesHomeExpressionExpandsTilde() {
        // `~`/`~/foo` are meaningful on the *remote* host. Local tilde
        // expansion would use the wrong user's home for SSH profiles, so we
        // rewrite to `$HOME` and let the remote shell expand it.
        #expect(remoteHermesHomeExpression(hermesHome: "~") == "$HOME")
        #expect(remoteHermesHomeExpression(hermesHome: "~/.custom-hermes") == "$HOME/.custom-hermes")
        #expect(remoteHermesHomeExpression(hermesHome: "~/work/hermes") == "$HOME/work/hermes")
    }

    @Test
    func buildRemoteHermesHomeResolveCommandHonorsShellWrapper() {
        // The resolve command runs through the profile's shell mode so that
        // login shells get a chance to source `~/.zprofile` / `.bash_profile`
        // — where users typically export `HERMES_HOME`. Without the wrapper,
        // the non-interactive ssh path would see an empty env and always
        // fall back to `$HOME/.hermes`.
        let direct = buildRemoteHermesHomeResolveCommand(
            hermesHome: nil,
            remoteShellMode: .direct,
            remoteShellPrefix: nil
        )
        #expect(direct == "printf '%s\\n' \"${HERMES_HOME:-$HOME/.hermes}\"")

        let bash = buildRemoteHermesHomeResolveCommand(
            hermesHome: nil,
            remoteShellMode: .bashLogin,
            remoteShellPrefix: nil
        )
        #expect(bash.hasPrefix("bash -lc "))
        #expect(bash.contains("${HERMES_HOME:-$HOME/.hermes}"))

        let zsh = buildRemoteHermesHomeResolveCommand(
            hermesHome: "~/.custom-hermes",
            remoteShellMode: .zshLogin,
            remoteShellPrefix: nil
        )
        #expect(zsh.hasPrefix("zsh -lc "))
        #expect(zsh.contains("$HOME/.custom-hermes"))

        let absolute = buildRemoteHermesHomeResolveCommand(
            hermesHome: "/var/hermes",
            remoteShellMode: .shLogin,
            remoteShellPrefix: nil
        )
        #expect(absolute.hasPrefix("sh -lc "))
        #expect(absolute.contains("/var/hermes"))

        let custom = buildRemoteHermesHomeResolveCommand(
            hermesHome: nil,
            remoteShellMode: .custom,
            remoteShellPrefix: "mise exec --"
        )
        #expect(custom.hasPrefix("mise exec -- "))
        #expect(custom.contains("${HERMES_HOME:-$HOME/.hermes}"))
    }

    #if os(macOS)
    /// Locks in that the NIO-SSH transport (via `buildHermesRemoteCommand`)
    /// sends the **same** wrapped command the system-ssh transport (via
    /// `SSHTransport.makeArguments`) appends as its final argv. Without
    /// this guard, a tweak to either path could silently start producing
    /// divergent remote command lines across transports.
    @Test
    func systemSSHAndBuilderProduceIdenticalRemoteCommand() {
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "example.com",
            user: "me",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519",
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes",
            remoteShellMode: .bashLogin
        )
        let arguments = SSHTransport.makeArguments(
            host: profile.host ?? "",
            user: profile.user,
            port: profile.port,
            identityFile: profile.identityFile,
            hermesPath: profile.hermesPath,
            hermesHome: profile.hermesHome,
            remoteShellMode: profile.remoteShellMode,
            remoteShellPrefix: profile.remoteShellPrefix
        )
        #expect(arguments.last == buildHermesRemoteCommand(profile: profile))
    }
    #endif
}
