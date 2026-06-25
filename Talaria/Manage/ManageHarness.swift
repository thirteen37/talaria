import Foundation
import HermesKit
import SwiftUI

/// Shared banner used by every Manage surface so SSH/runtime errors render
/// identically across Skills/Tools/Cron/Logs/Doctor/Updates. Keeping the look
/// in one place prevents the "same SSH error shows orange here and red there"
/// inconsistency that earlier per-view banners produced.
struct ManageBanner: View {
    enum Severity {
        /// Hard runtime failure (SSH error, command failed, parse error). Red.
        case error
        /// Soft warning (feature unavailable in this Hermes version). Orange.
        case warning
    }

    let severity: Severity
    let message: String

    private var color: Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        }
    }

    private var systemImage: String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(message).font(.caption).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            // Opaque neutral base so a translucent macOS title bar samples the
            // window background — not the saturated banner color — when the
            // strip sits flush beneath it. The visible tint is unchanged.
            Rectangle()
                .fill(.background)
                .overlay(color.opacity(0.12))
        }
    }
}

extension View {
    /// Attaches a manage-surface banner to the top of the view as a safe-area
    /// inset, so the banner sits *below* the window toolbar rather than
    /// bleeding behind it. macOS windows draw content underneath a
    /// translucent toolbar by default; placing the banner inside a plain
    /// `VStack` at y=0 lets its background tint the toolbar region. Hooking
    /// into the safe area moves the banner into the content region cleanly.
    @ViewBuilder
    func manageBanner(_ message: String?, severity: ManageBanner.Severity = .error) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let message {
                ManageBanner(severity: severity, message: message)
            }
        }
    }
}

/// Returns a banner string when the profile's Hermes version is known and is
/// below the capability's pin. Returns `nil` when the version is unknown
/// (the user hasn't probed yet — don't preemptively warn) or when the
/// capability is supported.
func capabilityBanner(
    _ capability: HermesCapability,
    feature: String,
    version: HermesVersion?,
    table: CapabilityTable = CapabilityTable()
) -> String? {
    guard let version else { return nil }
    if table.has(capability, in: version) { return nil }
    guard let minimum = table.minimumVersions[capability] else { return nil }
    return "\(feature) requires Hermes \(format(minimum)) or later (this server is at \(format(version)))."
}

/// Renders a `HermesVersion` for user-facing messages, including any
/// `-prerelease` suffix. Without the suffix a user on `1.0.0-rc.1` against a
/// pin of `1.0.0` would see "requires 1.0.0 or later (this server is at
/// 1.0.0)" — correct semver semantics but visually contradictory.
private func format(_ version: HermesVersion) -> String {
    var rendered = "\(version.major).\(version.minor).\(version.patch)"
    if let prerelease = version.prerelease {
        rendered += "-\(prerelease)"
    }
    return rendered
}

/// View-model for "list + toggle" Manage surfaces (Skills, Tools). Holds the
/// admin runner, the current rows, and an error string for the banner.
/// Generic over `Row` so both Skills and Tools reuse the same refresh/toggle
/// plumbing. Toggle work is delegated to per-surface closures so the runner
/// command (e.g. `skills enable`) is encapsulated there.
@MainActor
@Observable
final class ManageListHarness<Row: Identifiable & Sendable & Equatable> where Row.ID: Sendable {
    var rows: [Row] = []
    var lastError: String?
    var isLoading: Bool = false
    var selectionID: Row.ID?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// ``bannerKey`` so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    /// Surface id used to key this list's banners ("skills" / "tools"), set by the view.
    var bannerKey: String = "list"

    let runner: HermesAdminRunning?

    private let lister: @Sendable (HermesAdminRunning) async throws -> [Row]
    private let toggler: @Sendable (HermesAdminRunning, Row, Bool) async throws -> Void

    init(
        runner: HermesAdminRunning?,
        lister: @escaping @Sendable (HermesAdminRunning) async throws -> [Row],
        toggler: @escaping @Sendable (HermesAdminRunning, Row, Bool) async throws -> Void
    ) {
        self.runner = runner
        self.lister = lister
        self.toggler = toggler
    }

    func refresh() async {
        guard let runner else {
            rows = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await lister(runner)
            lastError = nil
            banners?.dismiss(key: bannerKey)
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    func setEnabled(_ row: Row, enabled: Bool) async {
        guard let runner else { return }
        do {
            try await toggler(runner, row, enabled)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }
}
