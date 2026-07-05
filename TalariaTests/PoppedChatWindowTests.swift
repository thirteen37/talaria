import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers the pop-out-a-chat-window plumbing that *is* unit-testable off the
/// SwiftUI multi-window runtime: the `WindowGroup` route value's identity
/// (protects dedup) and the live-harness registry's register/lookup/evict
/// behavior (protects the shared-connection guarantee + the close-with-source
/// lifetime).
@MainActor
@Suite
struct PoppedChatWindowTests {
    // MARK: PoppedChatRoute — Hashable / Equatable / Codable round-trip

    @Test
    func routeEqualityAndHashKeyOnBothFields() {
        let profile = UUID()
        let a = PoppedChatRoute(profileId: profile, sessionId: "s1")
        let b = PoppedChatRoute(profileId: profile, sessionId: "s1")
        let differentSession = PoppedChatRoute(profileId: profile, sessionId: "s2")
        let differentProfile = PoppedChatRoute(profileId: UUID(), sessionId: "s1")

        // Same {profile, session} → equal + same hash, so WindowGroup focuses
        // rather than spawning a duplicate.
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        // Either field differing → distinct identity → a separate window.
        #expect(a != differentSession)
        #expect(a != differentProfile)
    }

    @Test
    func routeCodableRoundTrips() throws {
        let route = PoppedChatRoute(profileId: UUID(), sessionId: "session-42")
        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(PoppedChatRoute.self, from: data)
        #expect(decoded == route)
    }

    // MARK: LiveHarnessRegistry — register / lookup / deregister / weak-evict

    @Test
    func registerThenLookupReturnsSameHarness() {
        let registry = LiveHarnessRegistry.shared
        let harness = ServerWindowHarness.makeMock()
        registry.register(harness)

        #expect(registry.harness(forProfile: harness.profile.id) === harness)

        registry.deregister(harness)
    }

    @Test
    func deregisterRemovesTheHarness() {
        let registry = LiveHarnessRegistry.shared
        let harness = ServerWindowHarness.makeMock()
        registry.register(harness)
        registry.deregister(harness)

        #expect(registry.harness(forProfile: harness.profile.id) == nil)
    }

    @Test
    func deregisterOnlyEvictsTheStoredInstance() {
        // A stale harness deregistering after a newer one took its profile slot
        // must not evict the live one (the Hermes-profile-switch case, where the
        // rebuilt harness reuses the same server-profile id).
        let registry = LiveHarnessRegistry.shared
        let profileId = UUID()
        let stale = ServerWindowHarness.makeMock(profileId: profileId)
        let live = ServerWindowHarness.makeMock(profileId: profileId)

        registry.register(stale)
        registry.register(live)
        registry.deregister(stale)

        #expect(registry.harness(forProfile: profileId) === live)
        registry.deregister(live)
    }

    @Test
    func serverSwitchSwapFreesTheOldProfileSlot() {
        // Models the in-window server switch: harness A (profile P1) is live, then
        // replaced by harness B (profile P2). `LiveHarnessRegistrar.sync` must
        // deregister A before registering B, so a pop-out on P1 stops resolving a
        // live harness (and dismisses) instead of zombie-ing over the torn-down
        // connection. Without the deregister, P1's slot would strand A.
        let registry = LiveHarnessRegistry.shared
        let a = ServerWindowHarness.makeMock()
        let b = ServerWindowHarness.makeMock()
        registry.register(a)
        // The swap, as the registrar performs it: deregister the old, register new.
        registry.deregister(a)
        registry.register(b)

        #expect(registry.harness(forProfile: a.profile.id) == nil)
        #expect(registry.harness(forProfile: b.profile.id) === b)
        registry.deregister(b)
    }

    @Test
    func lookupReturnsNilAfterHarnessDeallocates() {
        // Weak storage: a closed source window's harness deallocating auto-empties
        // its slot, so a restored/orphaned pop-out finds nothing and dismisses.
        let registry = LiveHarnessRegistry.shared
        var harness: ServerWindowHarness? = ServerWindowHarness.makeMock()
        let profileId = harness!.profile.id
        // Quiesce the background update loop so nothing outlives the strong ref.
        harness!.updates?.stopBackgroundChecks()
        registry.register(harness!)
        #expect(registry.harness(forProfile: profileId) != nil)

        harness = nil
        #expect(registry.harness(forProfile: profileId) == nil)
    }
}
