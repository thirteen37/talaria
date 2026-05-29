import SwiftUI

// macOS toolbar layout for `LogConsoleView`: a single trailing group of plain
// text buttons. The iOS mirror lives in `System/iOS/`.
extension View {
    func logConsoleToolbar(
        onCopy: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        toolbar {
            ToolbarItemGroup {
                Button("Copy", action: onCopy)
                Button("Refresh", action: onRefresh)
                Button("Done", action: onDismiss)
            }
        }
    }
}
