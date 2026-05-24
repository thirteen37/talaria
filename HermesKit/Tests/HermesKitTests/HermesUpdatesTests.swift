import Testing
@testable import HermesKit

@Suite
struct HermesUpdatesTests {
    @Test
    func parsesCurrentLatestCommaForm() throws {
        let status = try #require(HermesUpdates.parse("current 1.2.3, latest 1.3.0"))
        #expect(status.current == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(status.latest == HermesVersion(major: 1, minor: 3, patch: 0))
        #expect(status.available)
    }

    @Test
    func parsesCurrentLatestColonForm() throws {
        let status = try #require(HermesUpdates.parse("current: 2.0.0\nlatest: 2.0.0"))
        #expect(status.current == HermesVersion(major: 2, minor: 0, patch: 0))
        #expect(status.latest == HermesVersion(major: 2, minor: 0, patch: 0))
        #expect(!status.available)
    }

    @Test
    func parsesUpToDateForm() throws {
        let status = try #require(HermesUpdates.parse("Up to date (1.4.2)"))
        #expect(status.current == HermesVersion(major: 1, minor: 4, patch: 2))
        #expect(!status.available)
    }

    @Test
    func parsesUpdateAvailableArrowForm() throws {
        let status = try #require(HermesUpdates.parse("Update available: 1.2.3 → 1.3.0"))
        #expect(status.current == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(status.latest == HermesVersion(major: 1, minor: 3, patch: 0))
        #expect(status.available)
    }

    @Test
    func parsesUpdateAvailableAsciiArrowForm() throws {
        let status = try #require(HermesUpdates.parse("Update available: 1.2.3 -> 1.3.0"))
        #expect(status.current == HermesVersion(major: 1, minor: 2, patch: 3))
        #expect(status.latest == HermesVersion(major: 1, minor: 3, patch: 0))
        #expect(status.available)
    }
}
