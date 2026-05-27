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
