import SwiftUI

struct ToolsView: View {
    var body: some View {
        ContentUnavailableView("No Tools Loaded", systemImage: "hammer")
            .navigationTitle("Tools")
    }
}
