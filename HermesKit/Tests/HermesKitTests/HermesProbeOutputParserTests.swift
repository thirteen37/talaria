import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesProbeOutputParserTests {
    @Test
    func parsesPathAndVersionFromStdout() throws {
        let stdout = """
        /opt/homebrew/bin/hermes
        hermes 0.4.2
        """
        let result = try HermesProbeOutputParser.parse(stdout: stdout)
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
        let result = try HermesProbeOutputParser.parse(stdout: stdout)
        #expect(result.version.major == 1)
        #expect(result.version.prerelease == "rc.3")
    }

    @Test
    func rejectsUnparseableVersion() {
        let stdout = """
        /usr/local/bin/hermes
        hermes nightly
        """
        #expect(throws: HermesProbeError.self) {
            try HermesProbeOutputParser.parse(stdout: stdout)
        }
    }

    @Test
    func rejectsTruncatedOutput() {
        #expect(throws: HermesProbeError.self) {
            try HermesProbeOutputParser.parse(stdout: "/usr/local/bin/hermes\n")
        }
    }

    @Test
    func probeScriptQuotesPathAndUsesSetE() {
        #expect(
            HermesProbeOutputParser.makeProbeScript(hermesPath: "hermes")
                == "set -e; command -v 'hermes'; 'hermes' --version"
        )
        #expect(
            HermesProbeOutputParser.makeProbeScript(hermesPath: "/opt/bin/hermes")
                == "set -e; command -v '/opt/bin/hermes'; '/opt/bin/hermes' --version"
        )
    }
}
