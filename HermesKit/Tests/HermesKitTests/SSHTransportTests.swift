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
            "me@example.com",
            "env",
            "HERMES_HOME=/tmp/hermes",
            "/opt/bin/hermes",
            "acp",
        ])
    }
}
#endif
