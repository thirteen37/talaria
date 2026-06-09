import SwiftUI

// macOS toolbar layout for `LogConsoleView`: a single trailing group of plain
// text buttons. Done appears only when presented modally. The iOS mirror lives
// in `System/iOS/`.
extension View {
    func logConsoleToolbar(
        onCopy: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onDismiss: (() -> Void)?
    ) -> some View {
        toolbar {
            ToolbarItemGroup {
                Button("Copy", action: onCopy)
                    .help("Copy the logs")
                Button("Refresh", action: onRefresh)
                    .help("Refresh the logs")
                if let onDismiss {
                    Button("Done", action: onDismiss)
                        .help("Close")
                }
            }
        }
    }
}
