#if os(macOS)
import Testing
@testable import HermesKit

@Suite
struct SSHTransportTests {
    @Test
    func remoteCommandStartsAfterDestination() {
        let arguments = SSHTransport.makeArguments(
            host: "example.com",
            user: "me",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519",
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes"
        )

        #expect(arguments == [
            "-T",
            "-o",
            "BatchMode=yes",
            "-p",
            "2222",
            "-i",
            "~/.ssh/id_ed25519",
            "--",
            "me@example.com",
            "env",
            "'HERMES_HOME=/tmp/hermes'",
            "'/opt/bin/hermes'",
            "acp",
        ])
    }

    @Test
    func remoteCommandInsertsAreShellQuoted() {
        let arguments = SSHTransport.makeArguments(
            host: "example.com",
            hermesPath: "/opt/Hermes Bin/hermes'agent",
            hermesHome: "/var/lib/hermes data/it's; rm -rf ~"
        )

        #expect(arguments.suffix(4).elementsEqual([
            "env",
            "'HERMES_HOME=/var/lib/hermes data/it'\\''s; rm -rf ~'",
            "'/opt/Hermes Bin/hermes'\\''agent'",
            "acp",
        ]))
    }

    @Test
    func destinationIsSeparatedFromSSHOptions() {
        let arguments = SSHTransport.makeArguments(
            host: "-oProxyCommand=touch /tmp/bad",
            user: "-lroot"
        )

        #expect(arguments.contains("--"))
        #expect(arguments.suffix(4).elementsEqual([
            "--",
            "-lroot@-oProxyCommand=touch /tmp/bad",
            "'hermes'",
            "acp",
        ]))
    }
}
#endif
