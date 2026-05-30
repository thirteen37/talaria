import HermesKit
import Testing
@testable import Talaria

/// Exercises the backup (export / restore) branches that need no live dashboard
/// client. Mirrors `DoctorHarnessTests`' style: `@testable import Talaria`,
/// `@MainActor @Suite`, and trivial injected closures.
@MainActor
@Suite
struct ConfigEditorHarnessBackupTests {
    private struct StubError: Error {}

    private func makeHarness() -> ConfigEditorHarness {
        ConfigEditorHarness(
            defaultClient: { nil },
            runner: nil,
            profile: ServerProfile(name: "Test", kind: .local),
            transfer: nil,
            acquireScoped: { _ in throw StubError() },
            releaseScoped: { _ in }
        )
    }

    @Test
    func degradedExportBacksUpOnDiskYAML() {
        let harness = makeHarness()
        harness.dashboardUnavailable = true
        harness.yamlText = "a: 1\n"
        #expect(harness.backupYAML == "a: 1\n")
        #expect(harness.canExportBackup == true)
    }

    @Test
    func emptyExportWhenNothingLoaded() {
        let harness = makeHarness()
        #expect(harness.backupYAML == "")
        #expect(harness.canExportBackup == false)
    }

    @Test
    func restoreSurfacesParseFailureBeforeReachingClient() async {
        let harness = makeHarness()
        await harness.restore(fromYAML: ": : invalid")
        // Assert the specific parse-error message rather than just non-nil:
        // `resolveClient()` returns nil here (no default client) and would set
        // its own "Dashboard is unavailable" error, so a bare non-nil check
        // would pass even if the parse guard were removed.
        #expect(harness.lastError?.contains("isn't valid config YAML") == true)
    }
}
