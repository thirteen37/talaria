import Testing
@testable import HermesKit

/// Byte-identical command-line regression coverage for the Hermes TUI remote
/// launch line, mirroring `SSHTransportTests`' style for the ACP path. The
/// builder is pure (no `#if os(macOS)`), so these run on every platform.
@Suite
struct TUILaunchSpecTests {
    // MARK: New chat

    @Test
    func newChatDefaultProfileEmitsChatTUI() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes",
            remoteShellMode: .direct,
            remoteShellPrefix: nil
        )
        #expect(command == "env 'HERMES_HOME=/tmp/hermes' '/opt/bin/hermes' chat --tui")
    }

    @Test
    func newChatWithoutHermesHomeOmitsEnvPrefix() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .direct,
            remoteShellPrefix: nil
        )
        #expect(command == "'hermes' chat --tui")
    }

    @Test
    func newChatNamedProfileInsertsProfileFlag() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .direct,
            remoteShellPrefix: nil,
            hermesProfileName: "work"
        )
        #expect(command == "'hermes' -p 'work' chat --tui")
    }

    // MARK: Resume

    @Test
    func resumeAppendsResumeFlagAfterSubcommand() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes",
            remoteShellMode: .direct,
            remoteShellPrefix: nil,
            resume: "sess-123"
        )
        #expect(command == "env 'HERMES_HOME=/tmp/hermes' '/opt/bin/hermes' chat --tui -r 'sess-123'")
    }

    @Test
    func resumeNamedProfileOrdersProfileThenSubcommandThenResume() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .direct,
            remoteShellPrefix: nil,
            hermesProfileName: "work",
            resume: "sess-123"
        )
        #expect(command == "'hermes' -p 'work' chat --tui -r 'sess-123'")
    }

    @Test
    func emptyResumeIdIsTreatedAsNewChat() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .direct,
            remoteShellPrefix: nil,
            resume: ""
        )
        #expect(command == "'hermes' chat --tui")
    }

    // MARK: Shell wrapping

    @Test
    func bashLoginWrapsTheWholeChatLine() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .bashLogin,
            remoteShellPrefix: nil,
            resume: "abc"
        )
        #expect(command == "bash -lc ''\\''hermes'\\'' chat --tui -r '\\''abc'\\'''")
    }

    @Test
    func customPrefixWrapsTheWholeChatLine() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "hermes",
            hermesHome: nil,
            remoteShellMode: .custom,
            remoteShellPrefix: "mise exec --"
        )
        #expect(command == "mise exec -- ''\\''hermes'\\'' chat --tui'")
    }

    // MARK: Quoting safety

    @Test
    func metacharactersInPathAndResumeAreShellQuoted() {
        let command = buildHermesTUIRemoteCommand(
            hermesPath: "/opt/Hermes Bin/hermes'agent",
            hermesHome: "/var/lib/hermes data/it's; rm -rf ~",
            remoteShellMode: .direct,
            remoteShellPrefix: nil,
            resume: "id'; rm -rf ~"
        )
        #expect(command == "env 'HERMES_HOME=/var/lib/hermes data/it'\\''s; rm -rf ~' '/opt/Hermes Bin/hermes'\\''agent' chat --tui -r 'id'\\''; rm -rf ~'")
    }

    // MARK: Profile overload

    @Test
    func profileOverloadMatchesExplicitArguments() {
        let profile = ServerProfile(
            name: "remote",
            kind: .ssh,
            host: "example.com",
            hermesPath: "/usr/local/bin/hermes",
            hermesHome: "/srv/hermes",
            remoteShellMode: .zshLogin
        )
        let viaProfile = buildHermesTUIRemoteCommand(profile: profile, resume: "s1")
        let viaExplicit = buildHermesTUIRemoteCommand(
            hermesPath: "/usr/local/bin/hermes",
            hermesHome: "/srv/hermes",
            remoteShellMode: .zshLogin,
            remoteShellPrefix: nil,
            resume: "s1"
        )
        #expect(viaProfile == viaExplicit)
    }
}
