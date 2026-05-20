import SwiftUI

struct SessionsBrowser: View {
    var body: some View {
        ContentUnavailableView("No Sessions", systemImage: "clock.arrow.circlepath")
            .navigationTitle("Sessions")
    }
}
