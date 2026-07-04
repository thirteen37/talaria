import HermesKit
import SwiftUI

extension View {
    /// Step-1 reactor: presents the profile picker when a `talaria://share`
    /// arrives. Applied at the iOS window root. A per-window token claim ensures
    /// only one open window presents it (iPad multi-window). Consuming on appear
    /// *and* change mirrors `chatNotificationRouting`: a cold-launched window
    /// mounts with `pendingShare` already set, and `.onChange` never fires for a
    /// pre-existing value. See docs/architecture.md.
    func incomingShareProfilePicker() -> some View {
        modifier(IncomingShareProfilePicker())
    }

    /// Step-2 reactor: once the user has picked *this* window's profile, presents
    /// the session picker and prefills its composer. See docs/architecture.md.
    func incomingShareRouting(harness: ServerWindowHarness) -> some View {
        modifier(IncomingShareRouting(harness: harness))
    }
}

private struct IncomingShareProfilePicker: ViewModifier {
    @Environment(ProfileDirectory.self) private var directory
    @Environment(\.openWindow) private var openWindow
    private var coordinator: IncomingShareCoordinator { .shared }
    @State private var windowToken = UUID()
    @State private var presenting = false
    /// Non-nil when this dismissal is a profile pick: carries the chosen profile
    /// so `handleDismiss` hands off *after* the sheet is gone (rather than
    /// discarding), and doubles as the "was a pick" flag. Reset after each dismissal.
    @State private var pendingProfileSelection: UUID?

    func body(content: Self.Content) -> some View {
        content
            .onAppear { claimIfNeeded() }
            .onChange(of: coordinator.pendingShare) { _, _ in claimIfNeeded() }
            .onChange(of: coordinator.targetProfileId) { _, target in
                // A profile was chosen (here or in another window) — drop the picker.
                if target != nil { presenting = false }
            }
            .sheet(isPresented: $presenting, onDismiss: handleDismiss) {
                IncomingShareProfileSheet(
                    profiles: directory.profiles,
                    onSelect: { id in
                        // Defer the hand-off (which presents the session sheet — on
                        // iPhone in this *same* scene) until this sheet has fully
                        // dismissed: presenting a second sheet while the first is
                        // mid-dismiss drops it. Mirrors PhoneServerWindow's
                        // Browse→Settings `pendingSettings` deferral.
                        pendingProfileSelection = id
                        presenting = false
                    },
                    onCancel: { presenting = false }
                )
            }
    }

    private func claimIfNeeded() {
        guard coordinator.pendingShare != nil, coordinator.targetProfileId == nil else {
            presenting = false
            return
        }
        // First window to see the share claims presentation; others stand down.
        if coordinator.profilePickerPresenter == nil {
            coordinator.profilePickerPresenter = windowToken
        }
        presenting = (coordinator.profilePickerPresenter == windowToken)
    }

    /// Runs for *every* dismissal — Cancel, a profile pick, or an interactive
    /// swipe. A pick hands the share onward untouched; any other dismissal
    /// abandons it, so consume the staged bytes and clear the coordinator —
    /// otherwise they leak and `claimIfNeeded` re-presents on the next appearance.
    private func handleDismiss() {
        if let id = pendingProfileSelection {
            pendingProfileSelection = nil
            // The profile sheet is fully gone now, so handing off (which presents
            // the session sheet) no longer races a mid-dismiss. This is a pick, so
            // the share is *not* discarded — the target window's sheet owns cleanup.
            coordinator.selectProfile(id)
            // Focuses the existing window for `id`, or opens one — the same
            // mechanism the notification deep-link uses.
            openWindow(value: id)
            return
        }
        discardAndFinish()
    }

    private func discardAndFinish() {
        if let id = coordinator.pendingShare?.id {
            let store = PendingShareStore()
            Task { try? await store.consume(id: id) }
        }
        coordinator.finish()
    }
}

private struct IncomingShareRouting: ViewModifier {
    let harness: ServerWindowHarness
    private var coordinator: IncomingShareCoordinator { .shared }
    @State private var activeRoute: PendingShareRoute?

    func body(content: Self.Content) -> some View {
        content
            // Appear *and* change: a window opened in response to the profile pick
            // mounts with `targetProfileId` already set (cold-launch case).
            .onAppear { presentIfTargeted() }
            .onChange(of: coordinator.targetProfileId) { _, _ in presentIfTargeted() }
            .sheet(item: $activeRoute, onDismiss: handleDismiss) { route in
                IncomingShareSessionSheet(harness: harness, route: route) {
                    activeRoute = nil // dismiss; cleanup runs in `handleDismiss`
                }
            }
    }

    private func presentIfTargeted() {
        guard let route = coordinator.pendingShare,
              coordinator.targetProfileId == harness.profile.id else { return }
        activeRoute = route
    }

    /// Runs for every dismissal — a successful commit, Cancel, or an interactive
    /// swipe. In all cases the staged share is finished with: consume it (a commit
    /// already prefilled the composer; Cancel/swipe abandon it) and clear the
    /// coordinator so `presentIfTargeted` can't resurrect the sheet on re-appear.
    private func handleDismiss() {
        if let id = coordinator.pendingShare?.id {
            let store = PendingShareStore()
            Task { try? await store.consume(id: id) }
        }
        coordinator.finish()
    }
}
