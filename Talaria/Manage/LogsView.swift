import SwiftUI

struct LogsView: View {
    var body: some View {
        ContentUnavailableView("No Log Stream", systemImage: "doc.text.magnifyingglass")
            .navigationTitle("Logs")
    }
}
