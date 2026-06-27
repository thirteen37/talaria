import AppKit
import SwiftUI

/// Tracks whether ⌘ / ⌥ are currently held, so keyboard-shortcut hint badges can
/// reveal themselves only while the matching modifier is down. macOS half of the
/// `Platform/{macOS,iOS}` folder seam — the iOS half is an inert stub, so neither
/// needs `#if`.
///
/// A live `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` updates the
/// flags as they change (mirroring the static `NSEvent.modifierFlags` read in
/// `MenuModifiers`). The monitor is armed by the owning window's `onAppear` and
/// torn down on `onDisappear`.
@MainActor
@Observable
final class ModifierKeyMonitor {
    private(set) var command = false
    private(set) var option = false

    private var monitor: Any?

    /// Installs the flags-changed monitor (idempotent). The handler returns the
    /// event unchanged so it stays a pure observer of normal key routing.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags)
            return event
        }
    }

    /// Removes the monitor and clears the held state so a stale ⌘/⌥ can't linger
    /// after the window goes away.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        command = false
        option = false
    }

    private func update(from flags: NSEvent.ModifierFlags) {
        command = flags.contains(.command)
        option = flags.contains(.option)
    }
}
