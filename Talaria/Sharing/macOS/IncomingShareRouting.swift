import HermesKit
import SwiftUI

extension View {
    /// macOS no-op: the incoming Share Sheet feature is iOS-only (macOS has no
    /// share extension). The shared `DesktopServerWindow` — which also runs on
    /// iPad — calls this unconditionally; on macOS it does nothing. The real
    /// implementation lives in the `iOS/` seam. See docs/architecture.md.
    func incomingShareRouting(harness: ServerWindowHarness) -> some View { self }
}
