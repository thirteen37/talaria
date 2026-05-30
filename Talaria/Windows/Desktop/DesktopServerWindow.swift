import HermesKit
import SwiftUI

/// Desktop-class window shared by macOS and iPad: a `NavigationSplitView`
/// sidebar + detail with the full Browse section. No `#if`, no `Idiom` — the
/// few platform differences (window subtitle, the settings gear/sheet) route
/// through the seam layer. Every Browse surface is functional on iPad now that
/// the NIO admin runner is wired.
struct DesktopServerWindow: View {
    let profileId: UUID

    @Environment(ProfileDirectory.self) private var directory
    @Environment(RecentServers.self) private var recents
    @State private var harness: ServerWindowHarness?
    @State private var browse: BrowseDestination? = .sessions
    @State private var showingSettings = false
    /// Live profile shown in this window. Diverges from `profileId` (the
    /// `WindowGroup` launch value) once the user picks a different profile from
    /// the sidebar switcher; the harness rebuild keys off this.
    @State private var activeProfileId: UUID?

    private var currentProfileId: UUID { activeProfileId ?? profileId }

    var body: some View {
        Group {
            if let harness {
                content(harness: harness)
            } else if directory.profiles.isEmpty && !Platform.supportsLocalProfile {
                // iPad with no servers configured: offer the editor. macOS
                // always has the bundled local profile, so it never lands here.
                noServerConfiguredView
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(harness?.profile.name ?? directory.profile(id: currentProfileId)?.name ?? "Hermes")
        .platformWindowSubtitle(subtitle(for: harness?.profile ?? directory.profile(id: currentProfileId)))
        .task(id: currentProfileId) {
            await rebuildHarness()
        }
        // iPad: saving the first server (or a profile mutation while no harness
        // is live) connects without a relaunch. Harmless on macOS, which builds
        // a harness eagerly via the local fallback. Rebuilding while a harness
        // is live would drop the in-progress chat, so it's skipped then.
        .onChange(of: directory.profiles) { _, _ in
            guard harness == nil else { return }
            Task { await rebuildHarness() }
        }
        // Settings sheet (iPad only — macOS uses the Settings scene). Attached
        // at body level so the no-server empty state can present it too.
        .platformSettingsSheet(isPresented: $showingSettings) {
            DesktopProfileEditor(onDismiss: { showingSettings = false })
                .environment(directory)
        }
        .onDisappear {
            // Cancel the window-scoped log tailer + release the dashboard
            // refcount when the window closes.
            harness?.tearDown()
        }
    }

    @ViewBuilder
    private var noServerConfiguredView: some View {
        ContentUnavailableView {
            Label("No server configured", systemImage: "server.rack")
        } description: {
            Text("Add a remote server to start chatting.")
        } actions: {
            Button("Open Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
        }
    }

    @MainActor
    private func rebuildHarness() async {
        if UITestFlags.mockServer {
            // UI-test mode: bypass SSH entirely with an in-process ACP server.
            let previous = harness
            harness = ServerWindowHarness.makeMock()
            previous?.tearDown()
            return
        }
        await directory.reload()
        AppLog.general.info("rebuildHarness: \(directory.profiles.count) profile(s) configured")
        let previous = harness
        if let profile = ServerWindowHarness.resolveProfile(in: directory, requestedId: currentProfileId) {
            harness = ServerWindowHarness.make(profile: profile)
        } else {
            harness = nil
        }
        previous?.tearDown()
        // Spawn the per-profile dashboard once the previous harness released
        // its refcount. Done after `tearDown()` so the old supervisor is
        // released before the new one acquires.
        harness?.startDashboard()
    }

    /// In-place profile swap: tears the old harness down before swapping
    /// `activeProfileId`, which re-fires `.task` to build a fresh harness.
    private func switchProfile(to newId: UUID) {
        guard newId != currentProfileId else { return }
        recents.record(newId)
        harness?.tearDown()
        harness = nil
        browse = .sessions
        activeProfileId = newId
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        NavigationSplitView {
            sidebar(harness: harness)
        } detail: {
            detail(harness: harness)
        }
        .alert(
            "Trust this server?",
            isPresented: Binding(
                get: { harness.hostKeyCoordinator?.pending != nil },
                // Alerts only dismiss via their buttons (which resolve
                // explicitly), so the setter is a no-op — resolving here would
                // race the Trust button and could deny an approved key.
                set: { _ in }
            ),
            presenting: harness.hostKeyCoordinator?.pending
        ) { _ in
            Button("Trust") { harness.hostKeyCoordinator?.resolve(true) }
            Button("Cancel", role: .cancel) { harness.hostKeyCoordinator?.resolve(false) }
        } message: { request in
            Text(
                "First connection to \(request.host):\(request.port).\n\n"
                + "Key fingerprint:\n\(request.fingerprint)\n\n"
                + "Trust and remember this server? Only do this if the fingerprint matches your server."
            )
        }
    }

    @ViewBuilder
    private func sidebar(harness: ServerWindowHarness) -> some View {
        List {
            SessionsSidebar(
                store: harness.store,
                profile: harness.profile,
                profiles: directory.allProfiles,
                onSwitchProfile: switchProfile,
                notifications: harness.notifications,
                onOpenNotifications: {
                    harness.store.selection = nil
                    browse = .notifications
                }
            )
                .onChange(of: harness.store.selection) { _, newValue in
                    if newValue != nil {
                        browse = nil
                    }
                }

            if let error = harness.store.lastError {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Button("Dismiss") { harness.store.lastError = nil }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                        }
                    }
                }
            }

            // Surface a failed dashboard spawn window-wide. Without this the
            // dashboard surfaces sit on a perpetual "connecting…" placeholder
            // with no hint as to why.
            if let dashboardError = harness.dashboardError {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(dashboardError)
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }

            Section("Browse") {
                browseRow("Sessions", systemImage: "clock.arrow.circlepath", destination: .sessions, store: harness.store)
                browseRow("Skills", systemImage: "sparkles", destination: .skills, store: harness.store)
                browseRow("Tools", systemImage: "wrench.and.screwdriver", destination: .tools, store: harness.store)
                browseRow("Cron", systemImage: "calendar", destination: .cron, store: harness.store)
                browseRow("Profiles", systemImage: "person.2", destination: .profiles, store: harness.store)
                browseRow("Logs", systemImage: "doc.text", destination: .logs, store: harness.store)
                browseRow("Doctor", systemImage: "stethoscope", destination: .doctor, store: harness.store)
                browseRow("Updates", systemImage: "arrow.down.circle", destination: .updates, store: harness.store)
            }
        }
        // iPad surfaces a gear to open the editor (no Settings scene there);
        // no-op on macOS.
        .platformSettingsToolbarItem { showingSettings = true }
    }

    @ViewBuilder
    private func detail(harness: ServerWindowHarness) -> some View {
        if let selection = harness.store.selection,
           let session = harness.store.openSessions.first(where: { $0.id == selection }),
           let viewModel = harness.store.viewModel(for: session.id) {
            ChatView(viewModel: viewModel)
                .id(session.id)
                .background {
                    // ⌘W normally closes the window; when a session tab is
                    // selected we hijack the shortcut to close that tab
                    // instead. Disabled with no selection so the default
                    // `Performs Close` handles the keystroke as usual. Works on
                    // iPad with a hardware keyboard too — no `#if` needed.
                    Button("Close Session") {
                        if let id = harness.store.selection {
                            Task { await harness.store.closeTab(id) }
                        }
                    }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(harness.store.selection == nil)
                    .hidden()
                }
        } else {
            switch browse ?? .sessions {
            case .sessions:
                SessionsBrowser(store: harness.store, client: harness.dashboardClient)
            case .skills: SkillsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .tools: ToolsView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
            case .cron: CronView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .profiles: ProfilesView(runner: harness.store.adminRunner, profile: harness.profile, transfer: harness.snapshotTransfer)
            case .logs:
                LogsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .doctor:
                DoctorView(
                    doctor: harness.doctor,
                    profile: harness.profile,
                    client: harness.dashboardClient,
                    hermesVersion: harness.profile.version
                )
            case .updates: UpdatesView(updates: harness.updates, hermesVersion: harness.profile.version)
            case .notifications:
                NotificationsView(
                    center: harness.notifications,
                    onOpenDestination: { dest in browse = dest }
                )
            }
        }
    }

    /// SSH profiles show `user@host[:port]` so users can tell two same-named
    /// windows apart. Local profiles return an empty string — the subtitle slot
    /// is hidden when empty (and the seam is a no-op on iOS anyway).
    private func subtitle(for profile: ServerProfile?) -> String {
        guard let profile, profile.kind == .ssh else { return "" }
        let host = profile.host ?? ""
        guard !host.isEmpty else { return "" }
        let user = profile.user.map { "\($0)@" } ?? ""
        let port = profile.port.map { ":\($0)" } ?? ""
        return "\(user)\(host)\(port)"
    }

    private func browseRow(_ title: String, systemImage: String, destination: BrowseDestination, store: SessionsStore) -> some View {
        Button {
            store.selection = nil
            browse = destination
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(browse == destination && store.selection == nil ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
