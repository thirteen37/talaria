import SwiftUI

/// iOS mirror of `Platform/macOS/ModifierKeyMonitor.swift`. iOS has no
/// hardware-modifier hint surface (`Platform.showsKeyboardShortcutHints` is
/// `false` there), so this is an inert stub: the flags are always `false` and
/// `start()`/`stop()` are no-ops. Same symbol as the macOS half; the folder
/// excludes in `project.yml` compile only one per target, so neither needs `#if`.
@MainActor
@Observable
final class ModifierKeyMonitor {
    private(set) var command = false
    private(set) var option = false

    func start() {}
    func stop() {}
}
