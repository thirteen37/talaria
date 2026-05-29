import Testing
@testable import HermesKit

@Suite
struct CapabilityTableTests {
    @Test
    func returnsFalseWhenVersionUnknown() {
        let table = CapabilityTable()
        #expect(table.has(.acp, in: nil) == false)
    }

    @Test
    func returnsFalseWhenVersionBelowMinimum() {
        let table = CapabilityTable(minimumVersions: [
            .requiresDashboard: HermesVersion(major: 0, minor: 14, patch: 0),
        ])
        #expect(table.has(.requiresDashboard, in: HermesVersion(major: 0, minor: 13, patch: 99)) == false)
    }

    @Test
    func returnsTrueAtMinimumVersion() {
        let minimum = HermesVersion(major: 0, minor: 14, patch: 0)
        let table = CapabilityTable(minimumVersions: [.requiresDashboard: minimum])
        #expect(table.has(.requiresDashboard, in: minimum) == true)
    }

    @Test
    func returnsTrueAboveMinimumVersion() {
        let table = CapabilityTable(minimumVersions: [
            .requiresDashboard: HermesVersion(major: 0, minor: 14, patch: 0),
        ])
        #expect(table.has(.requiresDashboard, in: HermesVersion(major: 1, minor: 0, patch: 0)) == true)
    }

    @Test
    func returnsFalseForUnpinnedCapability() {
        let table = CapabilityTable(minimumVersions: [:])
        #expect(table.has(.acp, in: HermesVersion(major: 999, minor: 0, patch: 0)) == false)
    }

    @Test
    func prereleaseBelowReleaseIsRejected() {
        let table = CapabilityTable(minimumVersions: [
            .requiresDashboard: HermesVersion(major: 1, minor: 0, patch: 0),
        ])
        let prerelease = HermesVersion(major: 1, minor: 0, patch: 0, prerelease: "rc.1")
        #expect(table.has(.requiresDashboard, in: prerelease) == false)
    }

    @Test
    func defaultsCoverEveryCapabilityCase() {
        for capability in HermesCapability.allCases {
            #expect(CapabilityTable.defaults[capability] != nil, "missing default for \(capability)")
        }
    }

    @Test
    func requiresDashboardPinnedAtFirstShippingVersion() {
        let table = CapabilityTable()
        let preDashboard = HermesVersion(major: 0, minor: 13, patch: 99)
        let firstDashboard = HermesVersion(major: 0, minor: 14, patch: 0)
        #expect(table.has(.requiresDashboard, in: preDashboard) == false)
        #expect(table.has(.requiresDashboard, in: firstDashboard) == true)
    }
}
