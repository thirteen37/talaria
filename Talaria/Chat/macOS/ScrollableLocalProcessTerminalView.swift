import AppKit
import SwiftTerm

// macOS-only `LocalProcessTerminalView` subclass that makes mouse-wheel /
// two-finger trackpad scrolling work inside a full-screen Hermes TUI.
//
// SwiftTerm's stock `scrollWheel(with:)` only ever moves the view's *scrollback*
// buffer (`scrollUp`/`scrollDown`). A TUI runs on the **alternate screen
// buffer**, which has no scrollback, so those calls are no-ops and the wheel is
// never forwarded to the running program — scrolling is dead.
//
// We can't simply override `scrollWheel`: SwiftTerm declares it `public override`
// (not `open`), so Swift forbids overriding it from outside the module. Instead
// we install a local `.scrollWheel` `NSEvent` monitor while the view is on
// screen. When a scroll lands over this view on the alternate buffer we forward
// it ourselves — as an SGR mouse report or cursor-arrow presses (the iTerm2 /
// Terminal.app convention) — and swallow the event so SwiftTerm's dead handler
// never runs. Everything else (normal-buffer scrollback, events over other
// views) passes straight through to SwiftTerm untouched.
//
// All SwiftTerm API used here is `public` (verified against the pinned 1.11.2),
// so no fork or version bump is required.
final class ScrollableLocalProcessTerminalView: LocalProcessTerminalView {
    /// Live local event monitor while the view is in a window; nil otherwise.
    /// `nonisolated(unsafe)` so the (nonisolated) `deinit` can remove it; all
    /// access is on the main thread, where AppKit delivers events and dealloc.
    private nonisolated(unsafe) var scrollMonitor: Any?

    /// Accumulates fractional `deltaY` so a slow, precise trackpad drag still
    /// produces at least one discrete step once it crosses a line boundary.
    private var scrollAccumulator: CGFloat = 0

    /// Upper bound on steps emitted per event, so a fast flick can't spray the
    /// TUI with dozens of key presses / mouse reports at once.
    private static let maxStepsPerEvent = 5

    // MARK: Monitor lifecycle

    // The terminal view is detached from its window on tab switch and re-attached
    // on return (the controller outlives the window membership), so we arm the
    // monitor on attach and tear it down on detach.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeScrollMonitor()
        } else {
            installScrollMonitor()
        }
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollAccumulator = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        scrollAccumulator = 0
    }

    // MARK: Scroll handling

    /// Returns `nil` to consume the event (we handled it), or the event itself to
    /// let SwiftTerm's own `scrollWheel` run (normal-buffer scrollback, or events
    /// that don't belong to this view).
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, event.deltaY != 0 else { return event }

        // Only act when the pointer is over this terminal and nothing is layered
        // on top of it (e.g. the "session ended" overlay).
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }
        let hit = window.contentView?.hitTest(event.locationInWindow)
        guard hit === self || hit?.isDescendant(of: self) == true else { return event }

        // Normal buffer: let SwiftTerm's scrollback handler run as before.
        guard terminal.isCurrentBufferAlternate else { return event }

        scrollAccumulator += event.deltaY
        let steps = Int(scrollAccumulator)   // truncates toward zero
        guard steps != 0 else { return nil }
        scrollAccumulator -= CGFloat(steps)

        // deltaY > 0 means "scroll up" (back in history), matching SwiftTerm's
        // own `scrollUp` convention; flip here if direction feels reversed.
        let goingUp = steps > 0
        let count = min(abs(steps), Self.maxStepsPerEvent)

        if allowMouseReporting && terminal.mouseMode != .off {
            forwardWheelAsMouseReport(up: goingUp, count: count, event: event)
        } else {
            forwardWheelAsArrowKeys(up: goingUp, count: count)
        }
        return nil
    }

    /// Alt buffer with mouse tracking on: encode the wheel as SGR mouse button 4
    /// (up) / 5 (down), which `encodeButton` maps to codes 64/65, and emit it via
    /// the terminal's mouse report. Wheel reports are position-insensitive in
    /// practice, but we still approximate the cell under the pointer.
    private func forwardWheelAsMouseReport(up: Bool, count: Int, event: NSEvent) {
        let button = up ? 4 : 5
        let cell = approximateCell(for: event)
        for _ in 0 ..< count {
            let flags = terminal.encodeButton(
                button: button, release: false,
                shift: false, meta: false, control: false
            )
            terminal.sendEvent(buttonFlags: flags, x: cell.col, y: cell.row)
        }
    }

    /// Alt buffer with mouse tracking off: translate into cursor arrow-key
    /// presses, honouring the terminal's application-cursor mode.
    private func forwardWheelAsArrowKeys(up: Bool, count: Int) {
        let bytes: [UInt8]
        if up {
            bytes = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        } else {
            bytes = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        }
        for _ in 0 ..< count {
            send(bytes)
        }
    }

    /// Best-effort cell under the pointer, derived from the view's bounds split
    /// by (`cols`, `rows`). SwiftTerm's exact `calculateMouseHit`/`cellDimension`
    /// are `internal`, but this is good enough for position-insensitive wheel
    /// reports. The view is not flipped (origin bottom-left), so invert Y.
    private func approximateCell(for event: NSEvent) -> (col: Int, row: Int) {
        let cols = max(terminal.cols, 1)
        let rows = max(terminal.rows, 1)
        let local = convert(event.locationInWindow, from: nil)
        let cellWidth = bounds.width / CGFloat(cols)
        let cellHeight = bounds.height / CGFloat(rows)
        let col = cellWidth > 0 ? Int(local.x / cellWidth) : 0
        let rowFromTop = cellHeight > 0 ? Int((bounds.height - local.y) / cellHeight) : 0
        return (
            col: min(max(col, 0), cols - 1),
            row: min(max(rowFromTop, 0), rows - 1)
        )
    }
}
