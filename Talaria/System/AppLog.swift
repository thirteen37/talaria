import Foundation
import os

/// App-side loggers. Share the `com.talaria.*` subsystem prefix with
/// ``HermesLog`` so both stream together in macOS Console.app / sysdiagnose
/// (filter `subsystem:com.talaria`); see `docs/viewing-logs.md`.
enum AppLog {
    static let general = Logger(subsystem: "com.talaria.app", category: "general")
    static let session = Logger(subsystem: "com.talaria.app", category: "session")
    static let updates = Logger(subsystem: "com.talaria.app", category: "updates")
}
