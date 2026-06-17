import SwiftUI

/// A full-width field row that stacks a caption label above its control, instead
/// of `Form`'s default fixed left label column. Stacking keeps each row only as
/// wide as its control, so the Kanban detail/create panes fit a narrow secondary
/// pane without clipping the right-side buttons and steppers.
///
/// Follows the app's existing caption-label-above-control convention
/// (`AddCustomVarSheet` in `EnvironmentView.swift`, `ListFieldEditor` in
/// `ConfigFieldControl.swift`).
struct KanbanFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The caption is the control's accessible name (applied to `content`
            // below), so hide the visible label to avoid VoiceOver reading it
            // twice. Rows whose content is plain text (e.g. the ID) keep their
            // value via `.accessibilityValue(...)` at the call site, since
            // `.accessibilityLabel` would otherwise replace the spoken text.
            Text(label).font(.caption).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            content()
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled group of rows for the Kanban detail/create panes, replacing `Form`'s
/// `Section`. The panes render in a plain `ScrollView`/`VStack` rather than a
/// `Form` so they stay vertically scrollable and left-aligned, and only as wide
/// as the narrow secondary pane: a macOS `Form` reserves a fixed leading label
/// column (widening the pane and misaligning the stacked captions) and grows to
/// its content height instead of scrolling. Pass `nil` for an untitled group.
struct KanbanSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
