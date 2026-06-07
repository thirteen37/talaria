import HermesKit
import SwiftUI

/// Collapses the agent's system-prompt surface (`SOUL.md` + personalities) and
/// its memory surface (`MEMORY.md` / `USER.md`) behind one **Soul, Personalities
/// & Memory** Browse entry. A thin `TabbedDestinationView` wrapper — each child
/// keeps its own `.navigationTitle`, so the detail title tracks the active tab.
struct SoulPersonalitiesMemoryTabsView: View {
    let harness: ServerWindowHarness

    var body: some View {
        TabbedDestinationView(tabForFocus: { ref in
            if case .personality = ref { return "soul" }
            return nil
        }, tabs: [
            DestinationTab(id: "soul", title: "Soul & Personalities", systemImage: "theatermasks") {
                SoulAndPersonalitiesView(windowHarness: harness)
            },
            DestinationTab(id: "memory", title: "Memory", systemImage: "brain") {
                MemoryEditorView(windowHarness: harness)
            },
        ])
    }
}
