import Sparkle
import SwiftUI

/// Owns the Sparkle updater controller for the lifetime of the app.
///
/// Sparkle starts its update timer the moment `SPUStandardUpdaterController`
/// is initialised with `startingUpdater: true`; we hold the instance here so
/// it is not deallocated between scene rebuilds.
@MainActor
final class UpdateController: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }
}

/// Menu item that triggers `checkForUpdates`. Exposed as a separate view so
/// it can observe `canCheckForUpdates` and stay disabled while Sparkle is
/// already running a check.
struct CheckForUpdatesView: View {
    // `@StateObject` ties the checker's lifetime to this view's identity, so
    // SwiftUI does not rebuild a fresh `UpdaterChecker` (with its Combine
    // subscription resetting `canCheckForUpdates` to false until the first
    // tick) every time the parent body re-evaluates. Using `@ObservedObject`
    // here previously caused the menu item to flicker disabled across
    // re-renders.
    @StateObject private var checker: UpdaterChecker

    init(updater: SPUUpdater) {
        _checker = StateObject(wrappedValue: UpdaterChecker(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            checker.updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
    }
}

@MainActor
private final class UpdaterChecker: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
