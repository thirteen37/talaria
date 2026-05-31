import SwiftUI

/// Cross-platform editor for the Browse navigation list: drag to reorder the
/// manage pages and toggle each one's visibility. Backed by the global
/// ``SidebarLayout`` store, so changes apply to both the desktop sidebar and
/// the iPhone Browse sheet and survive relaunch. Lives in the shared `Talaria/`
/// tree (no `macOS/`/`iOS/` seam folder), so it compiles for both targets.
struct SidebarCustomizeView: View {
    @Environment(SidebarLayout.self) private var layout
    /// Provided only when presented as a dismissable sheet (the iPad / iPhone
    /// Settings sheets). The macOS Settings tab leaves it nil — the window's
    /// own close handles dismissal, so no in-content Done button is shown.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.orderedManageDestinations, id: \.self) { destination in
                        row(destination)
                    }
                    .onMove(perform: layout.move)
                } footer: {
                    #if os(iOS)
                    Text("Tap Edit to reorder. Hidden pages stay here so you can show them again.")
                    #else
                    Text("Drag to reorder. Hidden pages stay here so you can show them again.")
                    #endif
                }

                Section {
                    Button("Reset to Default", role: .destructive) {
                        layout.resetToDefault()
                    }
                    .help("Restore the default order and show all pages")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Sidebar Order")
            .toolbar {
                // iOS gates drag-reorder behind an explicit Edit mode (an
                // always-on `.active` editMode would route taps to reorder and
                // leave the per-row Toggle / Reset button non-interactive on
                // device). macOS lists reorder by drag in normal mode, so they
                // need no Edit toggle — and `EditButton` is iOS-only anyway.
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .help("Reorder pages")
                }
                #endif
                if let onDismiss {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDismiss)
                            .help("Close")
                    }
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
