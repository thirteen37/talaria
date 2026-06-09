import SwiftUI

/// Pure latch deciding when a scene-phase transition is a real
/// background→foreground round-trip worth probing the connection for.
///
/// `note(_:)` returns `true` exactly once per genuine resume: it arms when the
/// scene reaches `.background` and fires on the next `.active`. A bare
/// `.inactive` blip — a control-center pull or app-switcher peek that never
/// reaches `.background` — never arms it, so it never fires and a 2-second
/// app-switch costs no teardown.
///
/// Extracted from the SwiftUI seam so the fire/no-fire logic is unit-testable
/// without a host. Lives outside the `iOS/`/`macOS/` folder seams so the macOS
/// test target (which is where `TalariaTests` builds) can exercise it; SwiftUI's
/// `ScenePhase` is cross-platform.
struct BackgroundResumeLatch {
    private var didBackground = false

    /// Records a scene-phase value, returning `true` only when it completes a
    /// `.background` → `.active` round-trip — the one case that should trigger a
    /// connection probe.
    mutating func note(_ phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            didBackground = true
            return false
        case .active:
            guard didBackground else { return false }
            didBackground = false
            return true
        default: // .inactive — a transient blip, not a real backgrounding.
            return false
        }
    }
}
