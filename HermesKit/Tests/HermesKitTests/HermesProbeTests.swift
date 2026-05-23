#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesProbeTests {
    @Test
    func parsesPathAndVersionFromStdout() throws {
        let stdout = """
        /opt/homebrew/bin/hermes
        hermes 0.4.2
        """
        let result = try HermesProbe.parse(stdout: stdout)
        #expect(result.binaryPath == "/opt/homebrew/bin/hermes")
        #expect(result.version == HermesVersion(major: 0, minor: 4, patch: 2))
        #expect(result.versionRaw == "hermes 0.4.2")
        #expect(result.acpSupported)
    }

    @Test
    func parsesPrereleaseVersion() throws {
        let stdout = """
        /usr/local/bin/hermes
        hermes 1.0.0-rc.3 (build deadbeef)
        """
        let result = try HermesProbe.parse(stdout: stdout)
        #expect(result.version.major == 1)
        #expect(result.version.prerelease == "rc.3")
    }

    @Test
    func parseRejectsUnparseableVersion() {
        let stdout = """
        /usr/local/bin/hermes
        hermes nightly
        """
        #expect(throws: HermesProbeError.self) {
            try HermesProbe.parse(stdout: stdout)
        }
    }

    @Test
    func parseRejectsTruncatedOutput() {
        #expect(throws: HermesProbeError.self) {
            try HermesProbe.parse(stdout: "/usr/local/bin/hermes\n")
        }
    }
}
#endif
