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
        .background(color.opacity(0.12))
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setEnabled(_ row: Row, enabled: Bool) async {
        guard let runner else { return }
        do {
            try await toggler(runner, row, enabled)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
