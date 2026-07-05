import Foundation
import HermesKit

/// Identifies a chat session popped out into its own standalone macOS window.
///
/// Used as the value type of a second `WindowGroup(for:)` (see `TalariaApp`).
/// Both fields participate in identity so SwiftUI **dedups** on
/// `{profileId, sessionId}`: popping the same session twice focuses the existing
/// pop-out window instead of spawning a duplicate. `Codable` is required for a
/// `WindowGroup` value; `SessionId` is a `String` typealias, so both fields are
/// already `Hashable` + `Codable`.
struct PoppedChatRoute: Hashable, Codable {
    /// The `ServerProfile` id the source window is scoped to — the key the
    /// pop-out uses to find the live harness in `LiveHarnessRegistry`.
    let profileId: UUID
    /// The ACP session id whose shared view model the pop-out mirrors.
    let sessionId: SessionId
}
