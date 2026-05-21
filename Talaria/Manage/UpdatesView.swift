import SwiftUI

struct UpdatesView: View {
    var body: some View {
        ContentUnavailableView("No Update Check", systemImage: "arrow.triangle.2.circlepath")
            .navigationTitle("Updates")
    }
}
