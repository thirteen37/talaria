import HermesKit
import SwiftUI

@MainActor
@Observable
final class ProfileEditorState {
    enum ProbeState: Equatable {
        case idle
        case running
        case success(HermesProbeResult)
        case failure(String)
    }

    /// Selection identifies either a persisted profile (in `directory.profiles`)
    /// or the in-memory new draft (`pendingDraft.id`). Pending drafts are NOT
    /// written to disk until the user explicitly hits Save.
    var selection: UUID?
    var draft: ServerProfile?
    var pendingDraft: ServerProfile?
    var probeStates: [UUID: ProbeState] = [:]
    /// Tracks profiles where the user ran a successful probe in this session.
    /// Persisted profiles that already have a recorded `.version` are also
    /// considered "validated" via the `canSave` check.
    var validatedThisSession: Set<UUID> = []
    /// The just-typed password for the selected `.password` profile, lifted out
    /// of the detail views so "dirty" is computable where navigation happens.
    /// Bound directly by the form's `SecureField`. Empty on macOS (no password
    /// auth) and for non-password profiles.
    var passwordInput = ""
    /// The password loaded from the Keychain when the profile was selected, so
    /// `passwordChanged` is a dirty check against the pre-filled value rather
    /// than mere non-emptiness.
    var loadedPassword = ""
    /// Snapshot of a freshly-created pending draft, so an *untouched* new draft
    /// (still equal to this) doesn't nag the navigation guard. Set by the
    /// editor's `addNew()`.
    var pendingBaseline: ServerProfile?

    /// Whether the password field diverges from the loaded/stored value.
    var passwordChanged: Bool { passwordInput != loadedPassword }

    func select(_ id: UUID?, in directory: ProfileDirectory) {
        selection = id
        guard let id else {
            draft = nil
            loadPassword(for: nil)
            return
        }
        if id == pendingDraft?.id {
            draft = pendingDraft
        } else {
            draft = directory.profile(id: id)
        }
        loadPassword(for: draft)
    }

    /// Pre-fills `passwordInput`/`loadedPassword` from the Keychain for a
    /// `.password` profile so the field renders masked rather than empty when a
    /// password is in fact stored; resets both to `""` otherwise. No-op on macOS
    /// (`PasswordKeychain.get` returns nil there). Moved here from the detail
    /// view's `onAppear` so selection — the place navigation happens — owns it.
    private func loadPassword(for profile: ServerProfile?) {
        guard let profile, profile.authMethod == .password,
              let reference = profile.passwordKeychainReference,
              let stored = PasswordKeychain.get(reference: reference) else {
            passwordInput = ""
            loadedPassword = ""
            return
        }
        passwordInput = stored
        loadedPassword = stored
    }

    /// Whether the current draft diverges from its baseline — an unsaved new
    /// draft from its creation snapshot, a persisted profile from disk — either
    /// in content or in the password field. Drives the navigation guard.
    func isDirty(in directory: ProfileDirectory) -> Bool {
        guard let draft else { return false }
        if pendingDraft?.id == draft.id {
            return draft != pendingBaseline || passwordChanged
        }
        guard let existing = directory.profile(id: draft.id) else { return false }
        return existing != draft || passwordChanged
    }

    func updateDraft(_ profile: ServerProfile) {
        // Any user-driven edit invalidates the prior probe — the recorded
        // version came from a configuration that may no longer match.
        if let existing = draft, existing != profile {
            validatedThisSession.remove(profile.id)
            probeStates[profile.id] = .idle
        }
        draft = profile
        if pendingDraft?.id == profile.id {
            pendingDraft = profile
        }
    }

    func resetIfMissing(in directory: ProfileDirectory) {
        if let selection,
           directory.profile(id: selection) == nil,
           selection != pendingDraft?.id {
            self.selection = nil
            draft = nil
        }
    }

    /// Whether `draft` diverges from disk enough to be saveable, before the
    /// password-availability check. The probe-gating differs by platform
    /// (`Platform.requiresProbeBeforeSave`): macOS requires a successful probe
    /// for new/changed profiles; iOS accepts divergence and discovers
    /// capabilities at first connect.
    func baseCanSave(_ draft: ServerProfile, in directory: ProfileDirectory) -> Bool {
        if !Platform.requiresProbeBeforeSave {
            if pendingDraft?.id == draft.id { return true }
            guard let existing = directory.profile(id: draft.id) else { return false }
            return existing != draft
        }
        // Pending new drafts require at least one successful probe before they
        // can be persisted.
        if pendingDraft?.id == draft.id {
            return validatedThisSession.contains(draft.id)
        }
        // For persisted profiles, allow Save when the draft diverges from disk.
        // A previously validated `.version` keeps the profile saveable across
        // sessions; otherwise the user must Probe before Save.
        guard let existing = directory.profile(id: draft.id) else { return false }
        if existing == draft { return false }
        return validatedThisSession.contains(draft.id) || existing.version != nil
    }

    /// Single source of truth for whether the current draft can be saved,
    /// shared by the Save button's disabled state and `save()`.
    ///
    /// Password-auth profiles need a password available — either present in the
    /// field (`hasPasswordInput`) or already stored in the Keychain
    /// (`passwordKeychainReference`). They're saveable when content diverged
    /// (`baseCanSave`) or the password was edited (`passwordChanged` — covers
    /// rotating just the password on an otherwise-unchanged profile, which
    /// doesn't touch the `ServerProfile`). `passwordChanged` is a dirty check
    /// against the pre-filled value, not mere non-emptiness, so an unchanged
    /// saved profile correctly disables Save. Non-password drafts fall through
    /// to `baseCanSave`.
    static func isSaveable(
        _ draft: ServerProfile,
        hasPasswordInput: Bool,
        passwordChanged: Bool,
        baseCanSave: Bool
    ) -> Bool {
        if draft.kind == .ssh, draft.authMethod == .password {
            let hasPassword = hasPasswordInput || draft.passwordKeychainReference != nil
            return hasPassword && (baseCanSave || passwordChanged)
        }
        return baseCanSave
    }
}
