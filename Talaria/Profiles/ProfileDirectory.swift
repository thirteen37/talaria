import Foundation
import HermesKit
import SwiftUI

/// Shared in-memory mirror of ``ProfileStore`` with main-actor write helpers.
/// SwiftUI views observe `profiles`; mutations flow through this object so
/// the menu, editor, and any open windows all stay in sync without re-reading
/// disk on every event.
@MainActor
@Observable
final class ProfileDirectory {
    /// Synthetic id used to represent the bundled local Hermes — kept out of
    /// the persisted profile list so users can't accidentally delete it.
    static let localProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static let localProfile = ServerProfile(
        id: localProfileID,
        name: "Local Hermes",
        kind: .local
    )

    private(set) var profiles: [ServerProfile] = []
    var lastError: String?

    let store: ProfileStore

    init(store: ProfileStore = ProfileStore()) {
        self.store = store
    }

    /// Includes the synthetic local profile so menus / window resolution
    /// treat it as a first-class entry. iOS can't run local hermes (no
    /// `Process` / no `OneShotProcess`), so the bundled local profile is
    /// hidden there to keep it out of profile lists and the launch fallback.
    var allProfiles: [ServerProfile] {
        #if os(macOS)
        return [Self.localProfile] + profiles
        #else
        return profiles
        #endif
    }

    func reload() async {
        do {
            profiles = try await store.all()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func upsert(_ profile: ServerProfile) async {
        do {
            try await store.upsert(profile)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(id: UUID) async {
        do {
            try await store.delete(id: id)
            await reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func duplicate(id: UUID) async -> ServerProfile? {
        do {
            let copy = try await store.duplicate(id: id)
            await reload()
            return copy
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func profile(id: UUID) -> ServerProfile? {
        if id == Self.localProfileID {
            #if os(macOS)
            return Self.localProfile
            #else
            return nil
            #endif
        }
        return profiles.first(where: { $0.id == id })
    }
}
