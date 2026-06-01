import SwiftUI

/// Top navigation bar for the config editors: a key/description search field plus
/// a "Jump to section" menu that scroll-anchors the (virtualizing) `List`.
struct ConfigEditorNavBar: View {
    struct Section: Identifiable {
        let id: String       // matches the `.id(...)` on the List section
        let label: String
    }

    @Binding var searchText: String
    /// The currently *visible* sections (already search-filtered) so the jump menu
    /// and the list agree on what exists.
    let sections: [Section]
    let proxy: ScrollViewProxy

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keys", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                        .help("Clear the search")
                }
            }
            .frame(maxWidth: 320)

            if sections.count > 1 {
                Menu {
                    ForEach(sections) { section in
                        Button(section.label) { jump(to: section.id) }
                    }
                } label: {
                    Label("Jump to section", systemImage: "list.bullet.indent")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Scroll to a config section")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func jump(to id: String) {
        // `List` lays out off-screen rows with estimated heights, so a single
        // scrollTo lands on an estimated offset and drifts as real rows render.
        // First pass pulls the target into the rendered window (measuring it);
        // the second, next runloop, lands precisely.
        proxy.scrollTo(id, anchor: .top)
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .top) } }
    }
}
