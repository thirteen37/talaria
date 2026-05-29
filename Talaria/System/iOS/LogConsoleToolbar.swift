import SwiftUI

// iOS toolbar layout for `LogConsoleView`: Done on the leading edge, icon
// buttons for Copy/Refresh trailing. Mirror of `System/macOS/`.
extension View {
    func logConsoleToolbar(
        onCopy: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", action: onDismiss)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy logs")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh logs")
            }
        }
    }
}
