import SwiftUI

struct ServerWindow: View {
    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink("Chat") {
                    ChatView()
                }
                NavigationLink("Sessions") {
                    SessionsBrowser()
                }
                NavigationLink("Skills") {
                    SkillsView()
                }
                NavigationLink("Tools") {
                    ToolsView()
                }
                NavigationLink("Cron") {
                    CronView()
                }
                NavigationLink("Logs") {
                    LogsView()
                }
                NavigationLink("Doctor") {
                    DoctorView()
                }
                NavigationLink("Updates") {
                    UpdatesView()
                }
            }
            .navigationTitle("Hermes")
        } detail: {
            ChatView()
        }
    }
}
