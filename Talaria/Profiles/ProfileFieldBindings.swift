import HermesKit
import SwiftUI

/// String/Int field-binding helpers shared by the desktop and iPhone profile
/// editors. They bridge a `ServerProfile`'s optional `String?` / `Int?` fields
/// to the `String` bindings `TextField` wants, treating empty input as `nil`.
extension Binding where Value == ServerProfile {
    func string(_ keyPath: WritableKeyPath<ServerProfile, String?> & Sendable) -> Binding<String> {
        Binding<String>(
            get: { wrappedValue[keyPath: keyPath] ?? "" },
            set: { newValue in
                wrappedValue[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    func int(_ keyPath: WritableKeyPath<ServerProfile, Int?> & Sendable) -> Binding<String> {
        Binding<String>(
            get: { wrappedValue[keyPath: keyPath].map(String.init) ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                wrappedValue[keyPath: keyPath] = trimmed.isEmpty ? nil : Int(trimmed)
            }
        )
    }
}
