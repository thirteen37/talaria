import Testing
@testable import HermesKit

@Suite
struct HermesVersionTests {
    @Test
    func parsesVersionFromCLIOutput() {
        #expect(HermesVersion("hermes 1.2.3") == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(HermesVersion("1.2.3-beta.1") == HermesVersion(major: 1, minor: 2, patch: 3, prerelease: "beta.1"))
    }

    @Test
    func releaseSortsAfterPrerelease() {
        #expect(HermesVersion(major: 1, minor: 0, patch: 0) > HermesVersion(major: 1, minor: 0, patch: 0, prerelease: "beta.1"))
    }
}
