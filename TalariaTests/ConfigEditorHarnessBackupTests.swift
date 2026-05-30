import HermesKit
import Testing
@testable import Talaria

/// Exercises the backup (export / restore) branches that need no live dashboard
/// client. The backup logic lives on `ConfigEditingState` (one per profile), so
/// the tests construct that directly with trivial injected closures. Mirrors
/// `DoctorHarnessTests`' style: `@testable import Talaria`, `@MainActor @Suite`.
@MainActor
@Suite
struct ConfigEditorHarnessBackupTests {
    private struct StubError: Error {}

    private func makeState() -> ConfigEditingState {
        ConfigEditingState(
            profileName: HermesProfiles.defaultProfileName,
            defaultClient: { nil },
            serverProfile: ServerProfile(name: "Test", kind: .local),
            transfer: nil,
            acquireScoped: { _ in throw StubError() },
            releaseScoped: { _ in }
        )
    }

    @Test
    func degradedExportBacksUpOnDiskYAML() {
        let state = makeState()
        state.dashboardUnavailable = true
        state.yamlText = "a: 1\n"
        #expect(state.backupYAML == "a: 1\n")
        #expect(state.canExportBackup == true)
    }

    @Test
    func emptyExportWhenNothingLoaded() {
        let state = makeState()
        #expect(state.backupYAML == "")
        #expect(state.canExportBackup == false)
    }

    @Test
    func restoreSurfacesParseFailureBeforeReachingClient() async {
        let state = makeState()
        await state.restore(fromYAML: ": : invalid")
        // Assert the specific parse-error message rather than just non-nil:
        // `currentClient()` returns nil here (no default client) and would set
        // its own "Dashboard is unavailable" error, so a bare non-nil check
        // would pass even if the parse guard were removed.
        #expect(state.lastError?.contains("isn't valid config YAML") == true)
    }
}
