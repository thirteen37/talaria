import Foundation
import HermesKit

@MainActor
@Observable
final class ServerWindowController {
    var harness: ServerWindowHarness?
    var activeProfileId: UUID?
    var activeHermesProfile = HermesProfiles.defaultProfileName
    var hermesProfiles: [HermesProfileInfo] = []
    var hermesProfilesLoading = true

    func currentProfileId(default defaultProfileId: UUID) -> UUID {
        activeProfileId ?? defaultProfileId
    }

    func harnessKey(default defaultProfileId: UUID) -> ServerWindowHarnessKey {
        ServerWindowHarnessKey(
            server: currentProfileId(default: defaultProfileId),
            hermes: activeHermesProfile
        )
    }

    func rebuild(defaultProfileId: UUID, directory: ProfileDirectory) async {
        if UITestFlags.screenshotFixture {
            hermesProfilesLoading = false
            hermesProfiles = [
                HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true),
                HermesProfileInfo(name: "release", isDefault: false),
            ]

            let previous = harness
            let fixture = ServerWindowHarness.makeScreenshotFixture()
            harness = fixture
            previous?.tearDown()

            if UITestFlags.opensScreenshotChat {
                await fixture.openScreenshotSession()
                if let promptKind = UITestFlags.screenshotPromptKind {
                    try? await Task.sleep(for: .milliseconds(400))
                    fixture.emitScreenshotPrompt(promptKind)
                }
            }
            return
        }

        if UITestFlags.mockServer {
            hermesProfilesLoading = false
            let previous = harness
            harness = ServerWindowHarness.makeMock()
            previous?.tearDown()
            return
        }

        hermesProfilesLoading = true
        await directory.reload()
        AppLog.general.info("rebuildHarness: \(directory.profiles.count) profile(s) configured")

        let previous = harness
        let requestedId = currentProfileId(default: defaultProfileId)
        if let profile = ServerWindowHarness.resolveProfile(in: directory, requestedId: requestedId) {
            harness = ServerWindowHarness.make(profile: profile, hermesProfileName: activeHermesProfile)
        } else {
            harness = nil
        }
        previous?.tearDown()
        harness?.startDashboard()

        if let harness {
            Task { await loadHermesProfiles(harness: harness) }
        } else {
            hermesProfiles = []
        }
    }

    func loadHermesProfiles(harness: ServerWindowHarness) async {
        let client = harness.dashboardClient
        let profiles = await HermesProfiles.selectorProfiles(client: client)
        guard self.harness === harness else { return }
        hermesProfiles = profiles
        if client != nil { hermesProfilesLoading = false }
    }

    func reconcileHermesProfiles(harness: ServerWindowHarness) {
        Task {
            await loadHermesProfiles(harness: harness)
            guard self.harness === harness else { return }
            if !hermesProfiles.contains(where: { $0.name == activeHermesProfile }) {
                switchHermesProfile(to: HermesProfiles.defaultProfileName)
            }
        }
    }

    @discardableResult
    func switchProfile(to newId: UUID, launchProfileId: UUID, recents: RecentServers) -> Bool {
        guard newId != currentProfileId(default: launchProfileId) else { return false }
        recents.record(newId)
        harness?.tearDown()
        harness = nil
        hermesProfiles = []
        activeHermesProfile = HermesProfiles.defaultProfileName
        activeProfileId = newId
        return true
    }

    @discardableResult
    func switchHermesProfile(to name: String) -> Bool {
        guard name != activeHermesProfile else { return false }
        harness?.tearDown()
        harness = nil
        activeHermesProfile = name
        return true
    }

    func reopenSessions(
        harness: ServerWindowHarness,
        snapshot: WindowRestorationSnapshot,
        shouldContinue: @MainActor () -> Bool
    ) async -> [SessionId]? {
        var reopened: [SessionId] = []
        for id in snapshot.openSessionIds {
            guard shouldContinue(), self.harness === harness else { return nil }
            if await harness.store.reopenForRestore(id: id, title: snapshot.openTitles[id] ?? "") {
                reopened.append(id)
            }
        }
        guard shouldContinue(), self.harness === harness else { return nil }
        return reopened
    }

    func tearDown() {
        harness?.tearDown()
    }
}

struct ServerWindowHarnessKey: Hashable {
    let server: UUID
    let hermes: String
}
