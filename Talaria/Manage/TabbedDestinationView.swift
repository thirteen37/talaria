import SwiftUI

/// One inner tab of a multi-tab Browse destination.
struct DestinationTab: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Optional badge on the tab item — e.g. a pending-update indicator. `nil`
    /// shows no badge (the common case).
    let badge: Text?
    let content: AnyView

    init(id: String, title: String, systemImage: String, badge: Text? = nil, @ViewBuilder content: () -> some View) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.content = AnyView(content())
    }
}

/// Shared container for Browse destinations that host several inner tabs behind
/// one sidebar entry. Each child keeps its own `.navigationTitle`, so the detail
/// title tracks the active tab (same behavior the bespoke wrappers had).
struct TabbedDestinationView: View {
    let tabs: [DestinationTab]
    /// Maps a pending `EntityRef` focus to the tab id that hosts it, or nil if
    /// the ref isn't one of these tabs. When a focus lands, the container selects
    /// that tab so the right child is visible; the child then selects its row.
    var tabForFocus: ((EntityRef) -> String?)?
    /// Optional external selection so a parent (or a child via a closure) can
    /// drive which tab is shown — e.g. the Profiles tab linking to the Sync tab.
    private let externalSelection: Binding<String>?
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?
    @State private var internalSelection: String

    init(
        selection: Binding<String>? = nil,
        initialTabID: String? = nil,
        tabForFocus: ((EntityRef) -> String?)? = nil,
        tabs: [DestinationTab]
    ) {
        self.tabs = tabs
        self.tabForFocus = tabForFocus
        self.externalSelection = selection
        _internalSelection = State(initialValue: selection?.wrappedValue ?? initialTabID ?? tabs.first?.id ?? "")
    }

    private var selection: Binding<String> { externalSelection ?? $internalSelection }

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                tab.content
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .badge(tab.badge)
                    .tag(tab.id)
            }
        }
        // Switch to the tab that owns a pending focus. `.onAppear` covers a focus
        // set before this container appeared (the common cross-page case);
        // `.onChange` covers a tap while it's already on screen. The inner child
        // consumes the focus (selects the row, then clears it).
        .onAppear { selectTabForFocus() }
        .onChange(of: navigator?.pendingFocus) { _, _ in selectTabForFocus() }
    }

    private func selectTabForFocus() {
        guard let ref = navigator?.pendingFocus,
              let id = tabForFocus?(ref) else { return }
        if selection.wrappedValue != id { selection.wrappedValue = id }
    }
}
