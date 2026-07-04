import Foundation

/// App-wide hub for an incoming Share Sheet hand-off, mirroring
/// `ChatNotifier.shared`'s deep-link role. `onOpenURL` publishes the staged
/// share here; the window scene reacts by presenting the **profile** picker,
/// then — once a profile is chosen — the target profile's window presents its
/// **session** picker and prefills that session's composer. One share is in
/// flight at a time.
@MainActor
@Observable
final class IncomingShareCoordinator {
    static let shared = IncomingShareCoordinator()
    private init() {}

    /// The share awaiting hand-off; nil when idle.
    private(set) var pendingShare: PendingShareRoute?

    /// Ephemeral token of the window currently presenting the profile picker, so
    /// multiple open iPad windows don't all present it for the same share.
    var profilePickerPresenter: UUID?

    /// Set when the user picks a target profile: the window whose profile id
    /// matches claims the share, presents its session picker, and prefills.
    private(set) var targetProfileId: UUID?

    /// Publishes a freshly-opened share (from `onOpenURL`), resetting any prior
    /// in-flight claim state so a second share can't inherit the first's picker.
    func receive(_ route: PendingShareRoute) {
        pendingShare = route
        profilePickerPresenter = nil
        targetProfileId = nil
    }

    /// Records the user's chosen target profile (from the profile picker). The
    /// matching window's `incomingShareRouting` reactor takes it from here.
    func selectProfile(_ id: UUID) {
        targetProfileId = id
    }

    /// Clears all share state — after a successful prefill or a cancel.
    func finish() {
        pendingShare = nil
        profilePickerPresenter = nil
        targetProfileId = nil
    }
}
