import SwiftUI

@main
struct TalariaApp: App {
    var body: some Scene {
        WindowGroup {
            ServerWindow()
        }

        Settings {
            SettingsScene()
        }
    }
}
