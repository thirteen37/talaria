import Foundation
import Testing
@testable import HermesKit

@Suite
struct HindsightForwardSpecTests {
    private func profile(
        host: String? = "example.com",
        user: String? = "alice",
        port: Int? = nil,
        identityFile: String? = nil
    ) -> ServerProfile {
        var p = ServerProfile(name: "p", kind: .ssh)
        p.host = host
        p.user = user
        p.port = port
        p.identityFile = identityFile
        return p
    }

    @Test
    func buildsLocalForwardWithNoRemoteCommand() {
        let spec = DashboardSpawnSpec.forward(profile: profile(), localPort: 51000, remotePort: 8888)
        #expect(spec.executable.path == "/usr/bin/ssh")
        // The -L forward maps a local port to the remote loopback daemon port.
        let args = spec.arguments
        let lIdx = try! #require(args.firstIndex(of: "-L"))
        #expect(args[lIdx + 1] == "51000:127.0.0.1:8888")
        // -N: just forward, run no remote command.
        #expect(args.contains("-N"))
        // No remote command appended — the destination is the final argument.
        #expect(args.last == "alice@example.com")
    }

    @Test
    func carriesSSHBoilerplate() {
        let spec = DashboardSpawnSpec.forward(profile: profile(), localPort: 51000, remotePort: 8888)
        let joined = spec.arguments.joined(separator: " ")
        #expect(joined.contains("BatchMode=yes"))
        #expect(joined.contains("ConnectTimeout=5"))
        #expect(joined.contains("ServerAliveInterval=5"))
        #expect(joined.contains("ServerAliveCountMax=3"))
    }

    @Test
    func includesCustomPortAndIdentity() {
        let spec = DashboardSpawnSpec.forward(
            profile: profile(port: 2222, identityFile: "/keys/id_ed25519"),
            localPort: 51000,
            remotePort: 9123
        )
        let args = spec.arguments
        let pIdx = try! #require(args.firstIndex(of: "-p"))
        #expect(args[pIdx + 1] == "2222")
        let iIdx = try! #require(args.firstIndex(of: "-i"))
        #expect(args[iIdx + 1] == "/keys/id_ed25519")
        #expect(args.last == "alice@example.com")
    }

    @Test
    func hostOnlyDestinationWhenNoUser() {
        let spec = DashboardSpawnSpec.forward(profile: profile(user: nil), localPort: 5, remotePort: 6)
        #expect(spec.arguments.last == "example.com")
    }
}
