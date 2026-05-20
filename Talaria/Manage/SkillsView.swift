import SwiftUI

struct SkillsView: View {
    var body: some View {
        ContentUnavailableView("No Skills Loaded", systemImage: "wand.and.stars")
            .navigationTitle("Skills")
    }
}
