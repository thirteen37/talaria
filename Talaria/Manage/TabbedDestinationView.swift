import SwiftUI

/// One inner tab of a multi-tab Browse destination.
struct DestinationTab: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let content: AnyView

    init(id: String, title: String, systemImage: String, @ViewBuilder content: () -> some View) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.content = AnyView(content())
    }
}

/// Shared container for Browse destinations that host several inner tabs behind
/// one sidebar entry. Each child keeps its own `.navigationTitle`, so the detail
/// title tracks the active tab (same behavior the bespoke wrappers had).
struct TabbedDestinationView: View {
    let tabs: [DestinationTab]
    @State private var selection: String

    init(initialTabID: String? = nil, tabs: [DestinationTab]) {
        self.tabs = tabs
        _selection = State(initialValue: initialTabID ?? tabs.first?.id ?? "")
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(tabs) { tab in
                tab.content
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab.id)
            }
        }
    }
}
