import SwiftUI

struct ProfileEditor: View {
    var body: some View {
        Form {
            Section("Default Profile") {
                TextField("Name", text: .constant("Local Hermes"))
                TextField("Hermes Path", text: .constant("hermes"))
                TextField("Hermes Home", text: .constant("~/.hermes"))
            }
        }
        .padding()
    }
}
