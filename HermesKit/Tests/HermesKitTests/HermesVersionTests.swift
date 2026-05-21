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

    @Test
    func prereleaseNumericIdentifiersSortNumerically() {
        #expect(HermesVersion("1.0.0-beta.2")! < HermesVersion("1.0.0-beta.10")!)
        #expect(HermesVersion("1.0.0-rc.1")! < HermesVersion("1.0.0-rc.10")!)
    }

    @Test
    func prereleaseIdentifiersFollowSemverPrecedence() {
        #expect(HermesVersion("1.0.0-alpha")! < HermesVersion("1.0.0-alpha.1")!)
        #expect(HermesVersion("1.0.0-alpha.1")! < HermesVersion("1.0.0-alpha.beta")!)
        #expect(HermesVersion("1.0.0-alpha.beta")! < HermesVersion("1.0.0-beta")!)
        #expect(HermesVersion("1.0.0-beta")! < HermesVersion("1.0.0-beta.2")!)
        #expect(HermesVersion("1.0.0-beta.11")! < HermesVersion("1.0.0-rc.1")!)
    }
}
