import Foundation
import HermesKit

/// The navigation + open-session state a window needs to come back the way the
/// user left it after iOS terminates the suspended app (a cold relaunch). SwiftUI
/// `@State` survives an in-memory background→foreground round-trip, but a kill
/// wipes it; this is the on-disk record that restores it.
///
/// Captured on `scenePhase == .background` (the last reliable hook before iOS may
/// terminate) and on the window's navigation `.onChange`s.
struct WindowRestorationSnapshot: Codable, Equatable {
    /// Open `.acp`, non-read-only chat tabs — the re-resumable ones. Read-only
    /// and `.tui` tabs aren't restored (they can't be re-resumed live).
    var openSessionIds: [SessionId]
    /// Non-empty display titles for the open tabs, keyed by session id. Restored
    /// so a re-opened tab shows its name immediately — the dashboard's
    /// `sessionDetail` (used to check existence) carries only id/source, and a
    /// resumed session isn't guaranteed to replay a title, so the label would
    /// otherwise fall back to "Chat".
    var openTitles: [SessionId: String]
    /// The selected chat tab, if any.
    var selection: SessionId?
    /// The focused Browse destination (`BrowseDestination.rawValue`); nil when a
    /// chat is focused instead.
    var browse: String?
    /// The iPhone nested Browse sheet's stack (each `BrowseDestination.rawValue`).
    /// Empty on iPad / when the Browse sheet isn't drilled in.
    var browseSubPath: [String]
    /// The presented sheet: `"browse"`, `"allSessions"`, `"settings"`, or nil.
    var sheet: String?

    init(
        openSessionIds: [SessionId] = [],
        openTitles: [SessionId: String] = [:],
        selection: SessionId? = nil,
        browse: String? = nil,
        browseSubPath: [String] = [],
        sheet: String? = nil
    ) {
        self.openSessionIds = openSessionIds
        self.openTitles = openTitles
        self.selection = selection
        self.browse = browse
        self.browseSubPath = browseSubPath
        self.sheet = sheet
    }

    // Tolerant decoding: every field defaults when absent, so a snapshot written
    // by a build with a different field set still decodes instead of dropping the
    // whole file. Encoding stays synthesized.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openSessionIds = try c.decodeIfPresent([SessionId].self, forKey: .openSessionIds) ?? []
        openTitles = try c.decodeIfPresent([SessionId: String].self, forKey: .openTitles) ?? [:]
        selection = try c.decodeIfPresent(SessionId.self, forKey: .selection)
        browse = try c.decodeIfPresent(String.self, forKey: .browse)
        browseSubPath = try c.decodeIfPresent([String].self, forKey: .browseSubPath) ?? []
        sheet = try c.decodeIfPresent(String.self, forKey: .sheet)
    }
}

/// Persists one ``WindowRestorationSnapshot`` per server profile so a cold
/// relaunch can restore the window's navigation and re-open its live chats.
/// A direct clone of ``SessionsCwdStore``: an in-memory `[UUID: Snapshot]` map
/// mirrored to a JSON file in Application Support, atomic write, best-effort
/// decode-or-empty. Injectable `fileURL` for tests.
///
/// Keyed by **server `profile.id`** (not the `WindowGroup` UUID, which is
/// ephemeral, nor the Hermes profile name, which resets to `default` on launch).
/// An in-window server/Hermes-profile switch is therefore not restored across a
/// kill — v1 restores the launch profile only.
///
/// `@Observable` only so it flows through the SwiftUI environment (injected on
/// iOS, absent on macOS where the window is read as the optional `nil` form);
/// nothing observes it for re-rendering.
@MainActor
@Observable
final class WindowRestorationStore {
    private let fileURL: URL
    private var cache: [UUID: WindowRestorationSnapshot] = [:]

    init(fileURL: URL = WindowRestorationStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    func snapshot(for id: UUID) -> WindowRestorationSnapshot? {
        cache[id]
    }

    func record(_ snapshot: WindowRestorationSnapshot, for id: UUID) {
        if cache[id] == snapshot {
            return
        }
        cache[id] = snapshot
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UUID: WindowRestorationSnapshot].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort persistence; a failed write just means the next launch
            // restores from the previous snapshot (or nothing).
        }
    }

    static var defaultFileURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Talaria", isDirectory: true)
            .appendingPathComponent("window-restoration.json", isDirectory: false)
    }
}

/// Pure restore-decision logic, extracted so it's unit-testable without a live
/// dashboard or a SwiftUI host.
enum WindowRestoration {
    /// The selection to apply after a cold-launch restore:
    /// - No recorded selection (the user was on a Browse page with tabs open, or a
    ///   bare list) → keep none, so restore doesn't auto-focus a tab they'd closed
    ///   out of.
    /// - Recorded selection that re-opened → keep it.
    /// - Recorded selection that didn't re-open (e.g. a server-deleted session that
    ///   404'd) → fall back to the first tab that did, so the user isn't left on a
    ///   blank detail where they'd had a chat focused. Nil when none re-opened.
    static func resolvedSelection(recorded: SessionId?, reopened: [SessionId]) -> SessionId? {
        guard let recorded else { return nil }
        if reopened.contains(recorded) {
            return recorded
        }
        return reopened.first
    }
}
