import SwiftUI

// iOS toolbar layout for `LogConsoleView`: Done on the leading edge (only when
// presented modally), icon buttons for Copy/Refresh trailing. Mirror of
// `System/macOS/`.
extension View {
    func logConsoleToolbar(
        onCopy: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onDismiss: (() -> Void)?
    ) -> some View {
        toolbar {
            if let onDismiss {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onDismiss)
                        .help("Close")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy logs")
                .help("Copy the logs")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh logs")
                .help("Refresh the logs")
            }
        }
    }
}
