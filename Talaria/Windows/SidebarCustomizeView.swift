import SwiftUI

/// Cross-platform editor for the Browse navigation list: drag to reorder the
/// manage pages and toggle each one's visibility. Backed by the global
/// ``SidebarLayout`` store, so changes apply to both the desktop sidebar and
/// the iPhone Browse sheet and survive relaunch. Lives in the shared `Talaria/`
/// tree (no `macOS/`/`iOS/` seam folder), so it compiles for both targets.
struct SidebarCustomizeView: View {
    @Environment(SidebarLayout.self) private var layout
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.orderedManageDestinations, id: \.self) { destination in
                        row(destination)
                    }
                    .onMove(perform: layout.move)
                } footer: {
                    Text("Drag to reorder. Hidden pages stay here so you can show them again.")
                }
            }
            // iOS needs always-on edit mode for the drag handles; macOS lists
            // are reorderable by drag without it (and `editMode` is unavailable
            // there).
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Customize Sidebar")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset", role: .destructive) {
                        layout.resetToDefault()
                    }
                    .help("Restore the default order and show all pages")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .help("Close the customizer")
                }
            }
        }
    }

    private func row(_ destination: BrowseDestination) -> some View {
        let isVisible = !layout.isHidden(destination)
        return Toggle(isOn: Binding(
            get: { isVisible },
            set: { layout.setHidden(destination, hidden: !$0) }
        )) {
            Label(destination.title, systemImage: destination.systemImage)
        }
        .toggleStyle(.switch)
        .accessibilityLabel("\(destination.title) visible")
    }
}
