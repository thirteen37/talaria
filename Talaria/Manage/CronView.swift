import SwiftUI

struct CronView: View {
    var body: some View {
        ContentUnavailableView("No Cron Jobs", systemImage: "calendar.badge.clock")
            .navigationTitle("Cron")
    }
}
