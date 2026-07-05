import HermesKit
import SwiftUI

/// A standalone macOS window mirroring one chat session pulled out of its source
/// window (the browser-tab "pop out" idiom). It builds **no** harness, dashboard,
/// or connection: it resolves the *live* ``ServerWindowHarness`` the source window
/// already built from ``LiveHarnessRegistry`` and renders that harness's existing
/// chat view model in detached mode. Result: zero new sockets, the same in-memory
/// transcript + streaming, and the one shared permission prompt.
///
/// Lifetime follows the source, purely reactively (no connection refcount): if the
/// source window closes (its harness deregisters) or the mirrored tab is closed
/// (its view model vanishes from the store), the shared view model can no longer
/// be resolved and the pop-out dismisses itself. A pop-out restored on cold
/// relaunch finds no registered harness and dismisses immediately, so pop-outs
/// never resurrect. Its own composer draft and scroll position are view-local; the
/// connection, transcript, and streaming are shared.
struct PoppedChatWindow: View {
    let route: PoppedChatRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Reading the registry and the store's open-session list here subscribes
        // this view to both, so a deregister (source window closed) or a tab close
        // (session removed from the store) re-evaluates the body and dismisses.
        let harness = LiveHarnessRegistry.shared.harness(forProfile: route.profileId)
        Group {
            if let harness,
               harness.store.openSessions.contains(where: { $0.id == route.sessionId }),
               let viewModel = harness.store.viewModel(for: route.sessionId) {
                NavigationStack {
                    ChatView(viewModel: viewModel, store: harness.store, isDetached: true)
                }
            } else {
                // Source window/tab gone → close the pop-out. Honors "the
                // connection belongs to the main window": we never keep it alive.
                Color.clear.onAppear { dismiss() }
            }
        }
    }
}
