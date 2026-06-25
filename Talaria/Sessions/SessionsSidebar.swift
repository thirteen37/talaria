import HermesKit
import SwiftUI

struct SessionsSidebar: View {
    @Bindable var store: SessionsStore
    let profile: ServerProfile
    let profiles: [ServerProfile]
    let onSwitchProfile: (UUID) -> Void
    /// Hermes profiles (`hermes -p <name>`) available on the active server.
    let hermesProfiles: [HermesProfileInfo]
    /// The window's active Hermes profile name.
    let activeHermesProfile: String
    let onSwitchHermesProfile: (String) -> Void
    /// Whether the Hermes-profile list is still loading. Drives a placeholder
    /// row in the selector slot so it resolves in place rather than popping in.
    let isLoadingHermesProfiles: Bool
    /// When true, unselected rows render `.clear` so a translucent/glass host —
    /// the iPad & macOS split-view sidebar, whose `List` hides its grouped
    /// backdrop via `.scrollContentBackground(.hidden)` — shows through. When
    /// false (the iPhone navigation `List`, which has no glass backing) rows
    /// keep the opaque grouped white card so they don't expose the grey grouped
    /// section background. macOS always resolves to `.clear` regardless.
    let translucentRows: Bool

    @State private var renameTarget: SessionsStore.OpenSession?
    @State private var renameText: String = ""
    @State private var hoveredSessionId: SessionId?

    init(
        store: SessionsStore,
        profile: ServerProfile,
        profiles: [ServerProfile] = [],
        onSwitchProfile: @escaping (UUID) -> Void = { _ in },
        hermesProfiles: [HermesProfileInfo] = [],
        activeHermesProfile: String = HermesProfiles.defaultProfileName,
        onSwitchHermesProfile: @escaping (String) -> Void = { _ in },
        isLoadingHermesProfiles: Bool = false,
        translucentRows: Bool = true
    ) {
        self.store = store
        self.profile = profile
        self.profiles = profiles
        self.onSwitchProfile = onSwitchProfile
        self.hermesProfiles = hermesProfiles
        self.activeHermesProfile = activeHermesProfile
        self.onSwitchHermesProfile = onSwitchHermesProfile
        self.isLoadingHermesProfiles = isLoadingHermesProfiles
        self.translucentRows = translucentRows
    }

    var body: some View {
        Group {
            Section {
                ProfileHeader(
                    current: profile,
                    profiles: profiles,
                    onSelect: onSwitchProfile
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(auxRowBackground)

                // Second stacked menu: the window's active Hermes profile.
                // While the list is loading, hold the slot with a placeholder
                // row; once resolved it swaps to the selector in place — even
                // for a single (`default`-only) row — so the slot never appears
                // and then vanishes. A not-yet-online or failed dashboard also
                // resolves to that `default`-only row (see
                // `HermesProfiles.selectorProfiles`), so failure shows a
                // `default`-only menu rather than going empty. The empty branch
                // is defensive: the profile source always yields at least
                // `default`.
                if isLoadingHermesProfiles {
                    HermesProfileLoadingRow()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(auxRowBackground)
                } else if !hermesProfiles.isEmpty {
                    HermesProfileHeader(
                        active: activeHermesProfile,
                        profiles: hermesProfiles,
                        onSelect: onSwitchHermesProfile
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(auxRowBackground)
                }
            }

            Section("Chat") {
                ForEach(store.openSessions) { session in
                    row(for: session)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await store.openNew() }
                    } label: {
                        if store.isOpening {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 16, height: 16)
                                Text("Connecting…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        } else {
                            Label("New session", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isOpening)

                    // Launch a chat as the real Hermes TUI inside an embedded
                    // terminal instead of the native chat view (macOS only; the
                    // store injects no spec factory where unsupported).
                    if store.supportsTUI {
                        Button {
                            Task { await store.openTUI(resume: nil) }
                        } label: {
                            Image(systemName: "terminal")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.isOpening)
                        .help("New terminal (TUI) session")
                        .accessibilityLabel("New terminal session")
                    }
                }
                // Match the session rows: clear over a glass host so it shows
                // through, the grouped white card on the iPhone list.
                .listRowBackground(auxRowBackground)
            }
        }
        .sheet(item: $renameTarget) { target in
            renameSheet(for: target)
        }
    }

    @ViewBuilder
    private func row(for session: SessionsStore.OpenSession) -> some View {
        Button {
            store.selection = session.id
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Pin the status glyph to the title's cap-height center
                        // rather than the line-box center (which reads low
                        // against the cap-height digits in session IDs). The
                        // baseline guide floats it just above the baseline so its
                        // center lands on the glyphs' optical middle. The column
                        // is a fixed width (a touch wider than the old dot to fit
                        // the spinner/symbols); glyphs may overflow the 9pt height
                        // but stay centered on the dot's old optical point.
                        statusGlyph(for: session.id)
                            .frame(width: Self.statusGlyphWidth, height: 9)
                            .alignmentGuide(.firstTextBaseline) { $0.height + 2 }
                        Text(rowTitle(for: session))
                            .lineLimit(1)
                        // Distinguish embedded-terminal (TUI) tabs from native
                        // chat tabs; the status dot stays neutral for them
                        // (there's no gateway status stream).
                        if session.kind == .tui {
                            Image(systemName: "terminal")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .help("Terminal (TUI) session")
                        }
                    }
                    Text((session.cwd as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Indent under the title (glyph column width + HStack spacing).
                        .padding(.leading, Self.statusGlyphWidth + 8)
                }
                // Let the title/cwd column claim all available width so the
                // title truncates only at the row's edge. A bare Spacer() here
                // would split the flexible width with the Text and truncate it
                // prematurely.
                .frame(maxWidth: .infinity, alignment: .leading)
                closeButton(for: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground(for: session))
        .onHover { hovering in
            if hovering {
                hoveredSessionId = session.id
            } else if hoveredSessionId == session.id {
                hoveredSessionId = nil
            }
        }
        .contextMenu {
            Button("Rename…") {
                renameTarget = session
                renameText = session.title ?? ""
            }
            Button("Close tab") {
                Task { await store.closeTab(session.id) }
            }
            Divider()
            Button("Delete session", role: .destructive) {
                Task { await store.deleteSession(session.id) }
            }
        }
    }

    /// Unselected row background. Clear over a translucent host (iPad/macOS
    /// split-view sidebar) so the glass shows through; the opaque grouped white
    /// card over the iPhone navigation `List`, which has no glass backing.
    /// See `translucentRows` and `auxRowBackground`.
    private func rowBackground(for session: SessionsStore.OpenSession) -> Color {
        if store.selection == session.id {
            return Color.accentColor.opacity(0.15)
        }
        return auxRowBackground
    }

    /// Background for the non-selectable helper rows (profile headers, the
    /// loading placeholder, the "New session" row). Mirrors the unselected
    /// branch of `rowBackground` so every row resolves consistently: `.clear`
    /// over a glass host, the grouped white card on the iPhone list, always
    /// `.clear` on macOS (where `secondarySystemGroupedBackground` is absent).
    private var auxRowBackground: Color {
        #if os(iOS)
        return translucentRows ? Color.clear : Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color.clear
        #endif
    }

    /// Width of the fixed status-glyph column. Wider than the old 9pt dot so the
    /// `.working` mini spinner and the SF Symbols fit without clipping; the cwd
    /// row indents by this plus the HStack spacing to line up under the title.
    private static let statusGlyphWidth: CGFloat = 16

    /// Per-status glyph for a session row. Distinguished by **shape, not color**
    /// (monochrome, per user): `.primary`/`.secondary` only carry emphasis, not
    /// semantics. The icon is otherwise unlabeled, so each state restores the
    /// meaning the colored dot used to imply via `.help`/`.accessibilityLabel`.
    /// TUI tabs have no gateway status stream, so they read `.idle` → the quiet
    /// circle (the terminal glyph elsewhere in the row marks them as terminals).
    @ViewBuilder
    private func statusGlyph(for id: SessionId) -> some View {
        switch store.statuses[id] ?? .idle {
        case .idle:
            Image(systemName: "circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .help("Idle")
                .accessibilityLabel("Idle")
        case .working:
            // Animated spinner reads as "busy"; matches the "Connecting…" idiom.
            ProgressView()
                .controlSize(.mini)
                .help("Working")
                .accessibilityLabel("Working")
        case .awaitingInput:
            Image(systemName: "bell.badge.fill")
                .imageScale(.small)
                .foregroundStyle(.primary)
                .help("Waiting for your input")
                .accessibilityLabel("Waiting for your input")
        case let .error(message):
            // Surface the actual error in the tooltip/hint when we have one
            // (the associated string), falling back to the generic label.
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
                .foregroundStyle(.primary)
                .help(message.isEmpty ? "Error" : message)
                .accessibilityLabel("Error")
        }
    }

    @ViewBuilder
    private func closeButton(for session: SessionsStore.OpenSession) -> some View {
        Button {
            Task { await store.closeTab(session.id) }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(hoveredSessionId == session.id ? 1 : 0)
        .help("Close session")
    }

    private func shortId(_ id: SessionId) -> String {
        SessionIdFormatter.short(id)
    }

    /// Sidebar label for a tab. TUI tabs carry a synthetic `tui:…` id, so fall
    /// back to the resumed session's short id (resume) or a generic "Terminal"
    /// (new) rather than formatting the synthetic id.
    private func rowTitle(for session: SessionsStore.OpenSession) -> String {
        if let title = session.title, !title.isEmpty {
            return title
        }
        if session.kind == .tui {
            return session.resumeId.map(shortId) ?? "Terminal"
        }
        return shortId(session.id)
    }

    /// Sidebar row showing the active profile's name with a menu that
    /// lists every known profile. Selecting one swaps the window's harness
    /// in-place via the closure passed in from the host window
    /// (`DesktopServerWindow` / `PhoneServerWindow`).
    private struct ProfileHeader: View {
        let current: ServerProfile
        let profiles: [ServerProfile]
        let onSelect: (UUID) -> Void

        @State private var isHovering = false

        var body: some View {
            Menu {
                ForEach(profiles) { p in
                    Button {
                        if p.id != current.id {
                            onSelect(p.id)
                        }
                    } label: {
                        if p.id == current.id {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: current.kind == .ssh ? "network" : "desktopcomputer")
                        .imageScale(.small)
                        .foregroundStyle(.primary)
                    Text(current.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onHover { isHovering = $0 }
        }
    }

    /// Sidebar row showing the window's active Hermes profile with a menu that
    /// lists every profile on the server. Styled to read as a second, indented
    /// menu stacked under the server `ProfileHeader`. Selecting one rebuilds the
    /// window via the closure from the host window (`-p <name>`).
    private struct HermesProfileHeader: View {
        let active: String
        let profiles: [HermesProfileInfo]
        let onSelect: (String) -> Void

        @Environment(WindowNavigator.self) private var navigator: WindowNavigator?
        @State private var isHovering = false

        var body: some View {
            Menu {
                ForEach(profiles) { p in
                    Button {
                        if p.name != active {
                            onSelect(p.name)
                        }
                    } label: {
                        if p.name == active {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
                // Jump to the Profiles page (with the active profile selected),
                // separate from switching the window's active profile above.
                if navigator != nil {
                    Divider()
                    Button {
                        navigator?.open(.hermesProfile(name: active))
                    } label: {
                        Label("Manage Profiles…", systemImage: "square.stack.3d.up")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text("Profile: \(active)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onHover { isHovering = $0 }
        }
    }

    /// Placeholder shown in the Hermes-profile selector slot while the list is
    /// loading. Styled to match `HermesProfileHeader` (same padding/leading icon
    /// slot) so the swap to the resolved menu doesn't shift layout. Reuses the
    /// "Connecting…" spinner styling from the New-session row above.
    private struct HermesProfileLoadingRow: View {
        var body: some View {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text("Profile: …")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func renameSheet(for target: SessionsStore.OpenSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $renameText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    renameTarget = nil
                }
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let id = target.id
                    renameTarget = nil
                    guard !trimmed.isEmpty else {
                        return
                    }
                    Task { await store.renameSession(id, to: trimmed) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}
