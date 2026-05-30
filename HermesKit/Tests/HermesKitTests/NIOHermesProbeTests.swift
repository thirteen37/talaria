import Foundation
import Testing
@testable import HermesKit

@Suite
struct NIOHermesProbeTests {
    private func sshProfile(hermesPath: String = "hermes") -> ServerProfile {
        ServerProfile(name: "Box", kind: .ssh, host: "example.com", hermesPath: hermesPath)
    }

    @Test
    func runsLoginShellWrappedProbeScript() async throws {
        let stub = StubRemoteCommandRunner(
            result: RemoteCommandResult(
                exitCode: 0,
                stdout: "/opt/homebrew/bin/hermes\nhermes 0.4.2\n",
                stderr: ""
            )
        )
        let probe = NIOHermesProbe(runner: stub)

        let result = try await probe.probe(profile: sshProfile())

        #expect(stub.lastCommand == "sh -lc 'set -e; command -v '\\''hermes'\\''; '\\''hermes'\\'' --version'")
        #expect(result.binaryPath == "/opt/homebrew/bin/hermes")
        #expect(result.version == HermesVersion(major: 0, minor: 4, patch: 2))
    }

    @Test
    func nonzeroExitWithEmptyStdoutSurfacesBinaryNotFound() async throws {
        let stub = StubRemoteCommandRunner(
            result: RemoteCommandResult(exitCode: 127, stdout: "", stderr: "hermes: command not found")
        )
        let probe = NIOHermesProbe(runner: stub)

        await #expect(throws: HermesProbeError.self) {
            try await probe.probe(profile: sshProfile())
        }
    }

    @Test
    func transportThrowMapsToTransportFailed() async throws {
        let stub = StubRemoteCommandRunner(error: .authFailed("no identity"))
        let probe = NIOHermesProbe(runner: stub)

        do {
            _ = try await probe.probe(profile: sshProfile())
            Issue.record("expected probe to throw")
        } catch let error as HermesProbeError {
            guard case .transportFailed(.authFailed) = error else {
                Issue.record("expected .transportFailed(.authFailed), got \(error)")
                return
            }
        }
    }

    @Test
    func nonSSHProfileThrows() async throws {
        let stub = StubRemoteCommandRunner()
        let probe = NIOHermesProbe(runner: stub)

        await #expect(throws: HermesProbeError.self) {
            try await probe.probe(profile: ServerProfile(name: "Local", kind: .local, hermesPath: "hermes"))
        }
    }
}
