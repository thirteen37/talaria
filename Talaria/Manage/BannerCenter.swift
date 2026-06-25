import SwiftUI

/// Window-scoped (and Settings-scoped) hub for the **top-of-window** banner
/// strip. It unifies what used to be two unrelated systems: the connection /
/// session error rows tucked into the sidebar `List`, and the per-surface hard
/// errors that rode the in-surface `.manageBanner`. Both now route here and
/// render full-width across the top of the window, above the split view.
///
/// What stays in-surface: orange "requires Hermes X" **capability warnings**,
/// which remain on `.manageBanner(..., severity: .warning)` because they're a
/// property of *that* surface against *that* server version, not a window-wide
/// event.
///
/// Severity vocabulary mirrors `ManageBanner` (error = red, warning = orange)
/// and extends it with `success` (green) and `info` (blue). Successes and
/// non-persistent infos auto-dismiss after ~3s; errors persist until dismissed
/// or resolved (their backing state going `nil`).
///
/// Ownership is `ServerWindowHarness.banners` (window-scoped — it rebuilds with
/// the harness on a profile switch) plus a second Settings-local instance hosted
/// by `SettingsTabs` for the app-global Settings scene, which has no window
/// harness in scope. Same type, two hosts — the unification payoff.
@MainActor
@Observable
final class BannerCenter {
    /// Color/icon vocabulary shared with `ManageBanner` (error/warning) and
    /// extended for the two new transient kinds.
    enum Severity {
        case error, warning, success, info
    }

    /// A trailing action button (e.g. "Reconnect", "Dismiss"). Closures aren't
    /// `Equatable`, so identity is compared by `label` alone — sufficient because
    /// a keyed banner's action is stable for its key (the "session" banner always
    /// dismisses, the "dashboard" banner always reconnects).
    struct Action: Equatable {
        let label: String
        let perform: () -> Void

        nonisolated static func == (lhs: Action, rhs: Action) -> Bool {
            lhs.label == rhs.label
        }
    }

    struct Banner: Identifiable {
        let id = UUID()
        var severity: Severity
        var message: String
        /// Keyed banners replace in place (no stacking duplicates); a `nil` key
        /// always appends a fresh banner.
        var key: String?
        var action: Action?
        var autoDismiss: Bool
        /// Invoked when the row's ✕ is tapped, *in addition to* removing the
        /// banner. Bridged window banners set this to clear their backing state
        /// (e.g. `dashboardError = nil`) so a later identical-string failure
        /// still re-fires the edge-triggered `.onChange` bridge and re-shows.
        var onDismiss: (() -> Void)?
    }

    private(set) var banners: [Banner] = []

    /// Per-banner auto-dismiss tasks, kept so a manual dismiss (or a keyed
    /// replacement) can cancel the pending timer cleanly instead of letting a
    /// stale timer fire against a since-replaced banner id.
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Show

    /// Shows a banner. A non-nil `key` replaces any existing banner with the same
    /// key in place; a `nil` key always appends. Auto-dismissing banners schedule
    /// a ~3s timer keyed to their id.
    func show(_ severity: Severity, _ message: String, key: String? = nil, action: Action? = nil, autoDismiss: Bool = false, onDismiss: (() -> Void)? = nil) {
        let banner = Banner(severity: severity, message: message, key: key, action: action, autoDismiss: autoDismiss, onDismiss: onDismiss)
        if let key, let index = banners.firstIndex(where: { $0.key == key }) {
            cancelDismiss(banners[index].id)
            banners[index] = banner
        } else {
            banners.append(banner)
        }
        if autoDismiss {
            scheduleAutoDismiss(banner.id)
        }
    }

    /// Hard error — persists until dismissed or its backing state resolves.
    func error(_ message: String, key: String?, action: Action? = nil, onDismiss: (() -> Void)? = nil) {
        show(.error, message, key: key, action: action, autoDismiss: false, onDismiss: onDismiss)
    }

    /// Transient success — auto-dismisses after ~3s.
    func success(_ message: String, key: String? = nil) {
        show(.success, message, key: key, autoDismiss: true)
    }

    /// Informational notice. `persist: true` keeps it up (the "Building web UI…"
    /// progress note); otherwise it auto-dismisses like a success.
    func info(_ message: String, key: String?, persist: Bool = false, onDismiss: (() -> Void)? = nil) {
        show(.info, message, key: key, autoDismiss: !persist, onDismiss: onDismiss)
    }

    // MARK: - Dismiss

    func dismiss(id: UUID) {
        cancelDismiss(id)
        banners.removeAll { $0.id == id }
    }

    func dismiss(key: String) {
        for banner in banners where banner.key == key {
            cancelDismiss(banner.id)
        }
        banners.removeAll { $0.key == key }
    }

    // MARK: - Surface helpers

    /// Routes a surface's hard error to the top, keyed by the surface id so a
    /// later error from the same surface replaces it rather than stacking.
    func surfaceError(_ id: String, _ message: String) {
        error(message, key: id)
    }

    /// Confirms a surface's successful save: clears that surface's lingering
    /// error first, then shows a transient success.
    func surfaceSuccess(_ id: String, _ message: String) {
        dismiss(key: id)
        success(message)
    }

    // MARK: - Auto-dismiss plumbing

    private func scheduleAutoDismiss(_ id: UUID) {
        dismissTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    private func cancelDismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
    }
}

// MARK: - Host view

/// Renders the center's banners as a top-anchored `VStack`. One row per banner:
/// severity icon, message, optional action button, trailing dismiss "✕".
struct BannerHost: View {
    let center: BannerCenter

    var body: some View {
        if !center.banners.isEmpty {
            VStack(spacing: 0) {
                ForEach(center.banners) { banner in
                    BannerRow(banner: banner) {
                        // Clear any backing state first (bridged window banners),
                        // then remove the row.
                        banner.onDismiss?()
                        center.dismiss(id: banner.id)
                    }
                }
            }
        }
    }
}

private struct BannerRow: View {
    let banner: BannerCenter.Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if case .info = banner.severity, banner.action == nil, banner.autoDismiss == false {
                // A persistent info note (e.g. "Building web UI…") reads better
                // with a spinner than a static glyph.
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage).foregroundStyle(color)
            }

            Text(banner.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let action = banner.action {
                Button(action.label) { action.perform() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(action.label)
            }

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss")
            .help("Dismiss this notice")
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

    private var color: Color {
        switch banner.severity {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .info: return .blue
        }
    }

    private var systemImage: String {
        switch banner.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle"
        }
    }
}

extension View {
    /// Attaches the banner strip to the top of the view as a safe-area inset —
    /// the same pattern `manageBanner` uses, so the strip lands in the content
    /// region below the window toolbar rather than bleeding behind it.
    ///
    /// `active` gates whether the strip renders. The inset modifier is applied
    /// unconditionally (stable view identity across `active` flips — a compact
    /// iPad entering/leaving Slide Over doesn't tear down the hosted subtree);
    /// when `active` is false it just reserves nothing. The split-view layout
    /// uses this to host on the sidebar only in compact width, where the
    /// detail-pane host isn't on screen.
    func bannerHost(_ center: BannerCenter, active: Bool = true) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if active {
                BannerHost(center: center)
            }
        }
    }

    /// One shared modifier that publishes the center into the environment (so
    /// detail surfaces + sheets read it) and bridges the three pieces of window
    /// state that used to render as sidebar rows. It no longer hosts the visible
    /// strip — each window hosts that itself via `bannerHost` at the right
    /// altitude (the detail pane on the split-view layout, the full-width root on
    /// iPhone) so the strip never lands over the sidebar. The window state stays
    /// the source of truth — these bridges only mirror it into the center — so
    /// the existing `.onChange` gates that drive `hermesProfilesLoading` keep
    /// working untouched.
    func bridgeWindowBanners(harness: ServerWindowHarness) -> some View {
        self
            .environment(harness.banners)
            // The ✕ on each bridged banner clears its backing state (not just the
            // row) so a recurring failure with the identical error string still
            // re-fires this edge-triggered `.onChange` and re-shows the banner.
            // These closures are stored long-term inside `harness.banners`, which
            // `harness` owns by a strong `let`, so capturing `harness` strongly
            // would form `harness -> BannerCenter -> Banner closure -> harness` —
            // leaking the window (and its dashboard supervisor / ACP clients) on
            // close or profile switch. `[weak harness]` breaks the cycle; a fired
            // closure after teardown is a harmless no-op.
            .onChange(of: harness.store.lastError, initial: true) { _, error in
                if let error {
                    harness.banners.error(
                        error,
                        key: "session",
                        onDismiss: { [weak harness] in harness?.store.lastError = nil }
                    )
                } else {
                    harness.banners.dismiss(key: "session")
                }
            }
            .onChange(of: harness.dashboardError, initial: true) { _, error in
                if let error {
                    harness.banners.error(
                        error,
                        key: "dashboard",
                        action: .init(label: "Reconnect") { [weak harness] in harness?.reconnectDashboard() },
                        onDismiss: { [weak harness] in harness?.dashboardError = nil }
                    )
                } else {
                    harness.banners.dismiss(key: "dashboard")
                }
            }
            .onChange(of: harness.startupPhase, initial: true) { _, phase in
                if let phase {
                    // `.buildingWebUI` is confirmed (the build marker was seen),
                    // so we may assert the build; `.slowToStart` is alive-but-not
                    // -listening with no marker — likely still building, but
                    // unconfirmed, so hedge rather than claim a build outright.
                    harness.banners.info(
                        phase == .buildingWebUI ? "Building web UI…" : "Starting server…",
                        key: "webui",
                        persist: true,
                        onDismiss: { [weak harness] in harness?.startupPhase = nil }
                    )
                } else {
                    harness.banners.dismiss(key: "webui")
                }
            }
    }

    /// Dismisses the given surface banner key(s) when this view goes away, so a
    /// surface's pinned hard error doesn't linger over an unrelated surface after
    /// navigation. `BrowseDetailView` swaps surfaces by destroying the prior
    /// view's `@State` harness, and the tab containers swap sibling tabs the same
    /// way (`TabView` fires `onDisappear` on the outgoing tab), so the
    /// disappearing surface clears its own keyed banners here. Surface successes
    /// are keyless and auto-dismiss, so they're intentionally left alone.
    func dismissesBanner(_ keys: String..., from center: BannerCenter?) -> some View {
        onDisappear { for key in keys { center?.dismiss(key: key) } }
    }
}
