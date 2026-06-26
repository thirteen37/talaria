import HermesKit
import SwiftUI

/// Collapses the agent's system-prompt surface (`SOUL.md` + personalities) and
/// its memory surface (`MEMORY.md` / `USER.md`) behind one **Soul, Personalities
/// & Memory** Browse entry. A thin `TabbedDestinationView` wrapper — each child
/// keeps its own `.navigationTitle`, so the detail title tracks the active tab.
struct SoulPersonalitiesMemoryTabsView: View {
    let harness: ServerWindowHarness

    /// Gate the extra Hindsight tab on the provider the harness already resolved
    /// in the background when the dashboard connected — so switching to this
    /// destination never waits on a `GET /api/memory` round-trip.
    private var showsHindsight: Bool { harness.activeMemoryProvider == "hindsight" }

    var body: some View {
        TabbedDestinationView(tabForFocus: { ref in
            if case .personality = ref { return "soul" }
            return nil
        }, tabs: tabs)
        // Fallback only: if the provider wasn't resolved at connect time (e.g.
        // this destination opened before acquisition finished), resolve it in the
        // background. Never blocks the tabs — they render immediately either way.
        .task {
            if harness.activeMemoryProvider == nil {
                await harness.refreshMemoryProvider()
            }
        }
    }

    private var tabs: [DestinationTab] {
        var tabs: [DestinationTab] = [
            DestinationTab(id: "soul", title: "Soul & Personalities", systemImage: "theatermasks") {
                SoulAndPersonalitiesView(windowHarness: harness)
            },
            DestinationTab(id: "memory", title: "Memory", systemImage: "brain") {
                MemoryEditorView(windowHarness: harness)
            },
        ]
        if showsHindsight {
            tabs.append(
                DestinationTab(id: "hindsight", title: "Hindsight", systemImage: "sparkles.rectangle.stack") {
                    HindsightBrowserView(windowHarness: harness)
                }
            )
        }
        return tabs
    }
}
