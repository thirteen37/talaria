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
                } header: {
                    // Right-aligned so the caption sits above the trailing
                    // toggle column it describes, not the page names.
                    HStack {
                        Spacer()
                        Text("Show in Sidebar")
                    }
                } footer: {
                    #if os(iOS)
                    Text("Switch a page off to hide it from the sidebar — it stays here so you can show it again. Tap Edit, then drag the handles to reorder.")
                    #else
                    Text("Switch a page off to hide it from the sidebar — it stays here so you can show it again. Drag the handles to reorder.")
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
        return HStack(spacing: 8) {
            #if os(macOS)
            // macOS lists have no built-in reorder affordance, so show a grab
            // handle to signal (and give a safe spot for) drag-to-reorder.
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            #endif
            Toggle(isOn: Binding(
                get: { isVisible },
                set: { layout.setHidden(destination, hidden: !$0) }
            )) {
                Label(destination.title, systemImage: destination.systemImage)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("\(destination.title) visible")
        }
    }
}
