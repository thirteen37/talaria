import Foundation
import Testing
@testable import HermesKit

@Suite
struct NIOSSHHermesAdminRunnerTests {
    @Test
    func buildsWrappedRemoteCommandMatchingSystemSSHPath() async throws {
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "example.com",
            hermesPath: "hermes",
            remoteShellMode: .direct
        )
        let stub = StubRemoteCommandRunner()
        let runner = NIOSSHHermesAdminRunner(profile: profile, runner: stub)

        _ = try await runner.run(HermesAdminCommand(arguments: ["sessions", "list"]))

        #expect(stub.lastCommand == "env 'COLUMNS=400' 'hermes' 'sessions' 'list'")
        // Single source of truth: identical to what the macOS runner builds.
        #expect(
            stub.lastCommand
                == buildHermesAdminRemoteCommand(
                    profile: profile,
                    command: HermesAdminCommand(arguments: ["sessions", "list"])
                )
        )
    }

    @Test
    func foldsHermesHomeAndShellWrapperIntoRemoteCommand() async throws {
        let profile = ServerProfile(
            name: "Box",
            kind: .ssh,
            host: "example.com",
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes",
            remoteShellMode: .bashLogin
        )
        let stub = StubRemoteCommandRunner()
        let runner = NIOSSHHermesAdminRunner(profile: profile, runner: stub)

        _ = try await runner.run(HermesAdminCommand(arguments: ["doctor"]))

        let command = try #require(stub.lastCommand)
        #expect(command.hasPrefix("bash -lc "))
        #expect(command.contains("COLUMNS=400"))
        #expect(command.contains("HERMES_HOME=/tmp/hermes"))
    }

    @Test
    func mapsRemoteResultToHermesAdminResult() async throws {
        let profile = ServerProfile(name: "Box", kind: .ssh, host: "example.com", hermesPath: "hermes")
        let stub = StubRemoteCommandRunner(
            result: RemoteCommandResult(exitCode: 3, stdout: "out", stderr: "err")
        )
        let runner = NIOSSHHermesAdminRunner(profile: profile, runner: stub)

        let result = try await runner.run(HermesAdminCommand(arguments: ["tools", "list"]))

        #expect(result.exitCode == Int32(3))
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
    }

    @Test
    func nonSSHProfileReturnsErrorWithoutRunning() async throws {
        let profile = ServerProfile(name: "Local", kind: .local, hermesPath: "hermes")
        let stub = StubRemoteCommandRunner()
        let runner = NIOSSHHermesAdminRunner(profile: profile, runner: stub)

        let result = try await runner.run(HermesAdminCommand(arguments: ["sessions", "list"]))

        #expect(result.exitCode == 1)
        #expect(result.stderr == "profile is not an SSH profile")
        #expect(stub.lastCommand == nil)
    }
}
