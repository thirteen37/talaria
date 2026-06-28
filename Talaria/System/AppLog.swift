import Foundation
import os

/// App-side loggers. Share the `com.talaria.*` subsystem prefix with
/// ``HermesLog`` so the in-app ``LogConsole`` surfaces both.
enum AppLog {
    static let general = Logger(subsystem: "com.talaria.app", category: "general")
    static let session = Logger(subsystem: "com.talaria.app", category: "session")
    static let updates = Logger(subsystem: "com.talaria.app", category: "updates")
}
