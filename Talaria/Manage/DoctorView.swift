import SwiftUI

struct DoctorView: View {
    var body: some View {
        ContentUnavailableView("Doctor Has Not Run", systemImage: "stethoscope")
            .navigationTitle("Doctor")
    }
}
