import SwiftUI

struct ChatView: View {
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                ContentUnavailableView("No Session", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity, minHeight: 360)
            }

            Composer()
        }
        .navigationTitle("Chat")
    }
}

private struct Composer: View {
    @State private var prompt = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message Hermes", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)

            Button {
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .help("Send")
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }
}
