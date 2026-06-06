import AppKit
import HermesKit
import SwiftTerm
import SwiftUI

// macOS-only embedded-terminal surface for `.tui` session tabs. Renders the
// real `hermes chat --tui` (local) or `ssh -tt … hermes chat --tui` (remote)
// inside SwiftTerm's `LocalProcessTerminalView`, as an alternative to the
// native gateway-chat `ChatView`. iOS has no PTY/local-process path, so its seam returns
// an unavailable placeholder (never reached — TUI tabs can't be created there).

/// Owns a single live Hermes TUI terminal: the SwiftTerm view plus its PTY
/// child process. Retained by ``HermesTerminalRegistry`` (not SwiftUI) so the
/// process and scrollback survive tab switches — switching away detaches the
/// `NSView`, switching back re-attaches this same instance.
@MainActor
@Observable
final class HermesTerminalController: LocalProcessTerminalViewDelegate {
    /// The SwiftTerm view to embed. Stable for the controller's lifetime.
    @ObservationIgnored let terminalView: LocalProcessTerminalView
    private let spec: TUILaunchSpec
    private var started = false

    /// True once the child process exits, so the detail view can show the
    /// "Session ended — Relaunch" overlay.
    private(set) var hasExited = false
    private(set) var exitCode: Int32?

    init(spec: TUILaunchSpec) {
        self.spec = spec
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        self.terminalView.processDelegate = self
    }

    /// Spawns the process on first attach; idempotent on later re-attaches.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        launch()
    }

    /// Re-spawns after the process exited (the overlay's Relaunch button).
    func relaunch() {
        hasExited = false
        exitCode = nil
        launch()
    }

    /// Sends SIGTERM to the child (called when the tab closes).
    func terminate() {
        terminalView.terminate()
    }

    private func launch() {
        terminalView.startProcess(
            executable: spec.executableURL.path,
            args: spec.arguments,
            environment: environmentArray(),
            currentDirectory: spec.cwd
        )
    }

    /// Parent environment overlaid with the spec's extras (extras win, matching
    /// `LocalProcessTransport`), then a terminal type so hermes' Rich UI renders
    /// in color. Formatted as `KEY=VALUE` strings for SwiftTerm.
    private func environmentArray() -> [String] {
        var merged = spec.environment.merging(ProcessInfo.processInfo.environment) { mine, _ in mine }
        merged["TERM"] = "xterm-256color"
        merged["COLORTERM"] = "truecolor"
        return merged.map { "\($0.key)=\($0.value)" }
    }

    // MARK: LocalProcessTerminalViewDelegate
    //
    // SwiftTerm 1.13 isn't `@MainActor`-annotated, but `LocalProcess` posts
    // these on `DispatchQueue.main` (its default queue), so it's safe to assume
    // main-actor isolation here.

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.hasExited = true
            self.exitCode = exitCode
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Process-wide registry of live Hermes TUI terminals, keyed by the synthetic
/// `.tui` tab id. Holding controllers here — rather than in SwiftUI state — is
/// what lets a terminal survive tab switches; the session's tab id is globally
/// unique (`tui:<sessionId-or-uuid>`), so a single shared registry is enough.
@MainActor
final class HermesTerminalRegistry {
    static let shared = HermesTerminalRegistry()

    private var controllers: [SessionId: HermesTerminalController] = [:]

    /// Returns the controller for `tabId`, creating it (not yet started) from
    /// `spec` on first request. Later calls return the same live terminal.
    func controller(for tabId: SessionId, spec: TUILaunchSpec) -> HermesTerminalController {
        if let existing = controllers[tabId] { return existing }
        let controller = HermesTerminalController(spec: spec)
        controllers[tabId] = controller
        return controller
    }

    /// Terminates the child and drops the terminal for `tabId`.
    func terminate(_ tabId: SessionId) {
        controllers.removeValue(forKey: tabId)?.terminate()
    }
}

/// Detail-pane view for a `.tui` tab. Resolves (or creates) the registry
/// controller for the tab and embeds its terminal, with an exit overlay.
struct HermesTUIDetailView: View {
    let tabId: SessionId
    let spec: TUILaunchSpec

    var body: some View {
        let controller = HermesTerminalRegistry.shared.controller(for: tabId, spec: spec)
        TerminalRepresentable(controller: controller)
            .overlay(alignment: .center) {
                if controller.hasExited {
                    exitOverlay(controller: controller)
                }
            }
    }

    @ViewBuilder
    private func exitOverlay(controller: HermesTerminalController) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(controller.exitCode.map { "Session ended (exit \($0))" } ?? "Session ended")
                .font(.headline)
            Button {
                controller.relaunch()
            } label: {
                Label("Relaunch", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .help("Start a fresh Hermes TUI in this tab")
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
    }
}

/// Bridges SwiftTerm's `LocalProcessTerminalView` into SwiftUI. The view itself
/// lives on the controller (and thus the registry), so make/update just attach
/// the existing instance — there's no `dismantleNSView`, so a tab switch never
/// tears the process down (only `closeTab` does, via the registry).
private struct TerminalRepresentable: NSViewRepresentable {
    let controller: HermesTerminalController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.startIfNeeded()
        return controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Best-effort focus so the user can type immediately after the tab
        // appears, without a click. No-op until the view is in a window.
        if let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }
}
