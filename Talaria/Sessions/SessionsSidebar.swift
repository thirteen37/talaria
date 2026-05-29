import HermesKit
import SwiftUI

struct SessionsSidebar: View {
    @Bindable var store: SessionsStore
    let snapshot: RemoteSnapshot?
    let profile: ServerProfile
    let profiles: [ServerProfile]
    let onSwitchProfile: (UUID) -> Void
    let notifications: WindowNotificationCenter
    let onOpenNotifications: () -> Void

    @State private var renameTarget: SessionsStore.OpenSession?
    @State private var renameText: String = ""
    @State private var hoveredSessionId: SessionId?

    init(
        store: SessionsStore,
        snapshot: RemoteSnapshot? = nil,
        profile: ServerProfile,
        profiles: [ServerProfile] = [],
        onSwitchProfile: @escaping (UUID) -> Void = { _ in },
        notifications: WindowNotificationCenter,
        onOpenNotifications: @escaping () -> Void = {}
    ) {
        self.store = store
        self.snapshot = snapshot
        self.profile = profile
        self.profiles = profiles
        self.onSwitchProfile = onSwitchProfile
        self.notifications = notifications
        self.onOpenNotifications = onOpenNotifications
    }

    var body: some View {
        Group {
            Section {
                HStack(spacing: 6) {
                    ProfileHeader(
                        current: profile,
                        profiles: profiles,
                        onSelect: onSwitchProfile
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    NotificationBell(center: notifications, onOpen: onOpenNotifications)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Chat") {
                ForEach(store.openSessions) { session in
                    row(for: session)
                }

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
                .disabled(store.isOpening)
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
                        // Pin the dot to the title's cap-height center rather than
                        // the line-box center (which reads low against the
                        // cap-height digits in session IDs). The baseline guide
                        // floats the dot just above the baseline so its center
                        // lands on the glyphs' optical middle.
                        Circle()
                            .fill(statusColor(for: session.id))
                            .frame(width: 9, height: 9)
                            .alignmentGuide(.firstTextBaseline) { $0.height + 2 }
                        Text(session.title ?? shortId(session.id))
                            .lineLimit(1)
                    }
                    Text((session.cwd as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Indent under the title (dot width + HStack spacing).
                        .padding(.leading, 17)
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
        .listRowBackground(store.selection == session.id ? Color.accentColor.opacity(0.15) : Color.clear)
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

    private func statusColor(for id: SessionId) -> Color {
        switch store.statuses[id] ?? .idle {
        case .idle: return .secondary
        case .working: return .green
        case .error: return .red
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

    /// Sidebar row showing the active profile's name with a menu that
    /// lists every known profile. Selecting one swaps the window's harness
    /// in-place via the closure passed in from `ServerWindow`.
    private struct ProfileHeader: View {
        let current: ServerProfile
        let profiles: [ServerProfile]
        let onSelect: (UUID) -> Void

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
                        .foregroundStyle(.secondary)
                    Text(current.name)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
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
