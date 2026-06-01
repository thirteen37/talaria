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
    @Environment(SidebarLayout.self) private var sidebarLayout
    @Environment(NotificationSettings.self) private var notificationSettings
    @State private var harness: ServerWindowHarness?
    @State private var browse: BrowseDestination? = .sessions
    @State private var showingSettings = false
    /// Sidebar visibility, driven by our custom toggle. We manage it ourselves
    /// (rather than letting the system own the sidebar button) so the toggle can
    /// carry a notification badge that stays visible when the sidebar collapses.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Live profile shown in this window. Diverges from `profileId` (the
    /// `WindowGroup` launch value) once the user picks a different profile from
    /// the sidebar switcher; the harness rebuild keys off this.
    @State private var activeProfileId: UUID?
    /// Active Hermes profile (`hermes -p <name>`) the whole window is scoped to.
    /// Does not persist — resets to `default` on launch and on every server
    /// switch. The harness rebuild keys off this alongside the server id.
    @State private var activeHermesProfile = HermesProfiles.defaultProfileName
    /// Hermes profiles available on the active server, enumerated after the
    /// dashboard comes online. Drives the sidebar switcher; never fed into
    /// `.task(id:)` (that would loop the rebuild).
    @State private var hermesProfiles: [HermesProfileInfo] = []
    /// True while the Hermes-profile list is loading, so the sidebar shows a
    /// placeholder in the selector slot instead of popping the menu in. Cleared
    /// once the dashboard produces an authoritative answer (success or error).
    @State private var hermesProfilesLoading = true

    private var currentProfileId: UUID { activeProfileId ?? profileId }

    /// Combined rebuild identity: a change to either the server or the Hermes
    /// profile tears the harness down and rebuilds it.
    private var harnessKey: HarnessKey {
        HarnessKey(server: currentProfileId, hermes: activeHermesProfile)
    }

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
        .task(id: harnessKey) {
            await rebuildHarness()
        }
        // The dashboard comes online async, after `rebuildHarness` already ran
        // its first (client-less) profile load. Re-run once it lands so the
        // switcher upgrades from default-only to the live dashboard list,
        // mirroring the config editor's dashboard-ready re-load.
        .onChange(of: harness?.dashboardClient != nil) { _, hasClient in
            guard hasClient, let harness else { return }
            Task { await loadHermesProfiles(harness: harness) }
        }
        // Clear the loading placeholder if the dashboard fails to spawn: the
        // client stays nil so the success path never fires, leaving the spinner
        // up forever otherwise.
        .onChange(of: harness?.dashboardError != nil) { _, hasError in
            if hasError { hermesProfilesLoading = false }
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
            SettingsTabs(onDismiss: { showingSettings = false })
                .environment(directory)
                .environment(sidebarLayout)
                .environment(notificationSettings)
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
            // The mock never loads profiles and keeps a nil dashboard client, so
            // clear the loading flag here or the placeholder would spin forever.
            hermesProfilesLoading = false
            let previous = harness
            harness = ServerWindowHarness.makeMock()
            previous?.tearDown()
            return
        }
        // Re-arm the loading state so each rebuild/profile-switch re-shows the
        // placeholder until the dashboard resolves the list.
        hermesProfilesLoading = true
        await directory.reload()
        AppLog.general.info("rebuildHarness: \(directory.profiles.count) profile(s) configured")
        let previous = harness
        if let profile = ServerWindowHarness.resolveProfile(in: directory, requestedId: currentProfileId) {
            harness = ServerWindowHarness.make(profile: profile, hermesProfileName: activeHermesProfile)
        } else {
            harness = nil
        }
        previous?.tearDown()
        // Spawn the per-profile dashboard once the previous harness released
        // its refcount. Done after `tearDown()` so the old supervisor is
        // released before the new one acquires.
        harness?.startDashboard()
        // Enumerate the server's Hermes profiles for the sidebar switcher. Kept
        // out of `.task(id:)` (it isn't a rebuild trigger — that would loop) and
        // run as a detached child so a slow listing doesn't block the harness.
        if let harness {
            Task { await loadHermesProfiles(harness: harness) }
        } else {
            hermesProfiles = []
        }
    }

    /// Populates `hermesProfiles` for the switcher straight from the dashboard
    /// API (clean names + is-default flag). Stays default-only/hidden until the
    /// dashboard is online or if the call fails — no CLI `profile list` fallback,
    /// whose decorated table would leak marker glyphs into the menu. Re-run when
    /// `dashboardClient` lands (see the `.onChange` below) to upgrade the list.
    @MainActor
    private func loadHermesProfiles(harness: ServerWindowHarness) async {
        // Capture the client before the await: only a dashboard-backed load is
        // authoritative. The first client-less load returns default-only and
        // must keep the placeholder up until the dashboard lands.
        let client = harness.dashboardClient
        let profiles = await HermesProfiles.selectorProfiles(client: client)
        // Drop a stale listing if the window rebuilt its harness (server or
        // Hermes-profile switch) while this read was in flight — otherwise it
        // would overwrite the active harness's profiles with the previous one's,
        // offering `-p <name>`s the server lacks. Identity (not profile id) is
        // the right key: a Hermes-profile switch keeps the server id but builds
        // a fresh harness.
        guard self.harness === harness else { return }
        hermesProfiles = profiles
        if client != nil { hermesProfilesLoading = false }
    }

    /// Re-runs the Hermes-profile listing after a Profiles mutation (clone /
    /// rename / delete) so the sidebar switcher reflects the change. If the
    /// currently-active `-p <name>` no longer exists (it was renamed or
    /// deleted), falls back to `default` so the window isn't left scoped to a
    /// dead profile.
    @MainActor
    private func reconcileHermesProfiles(harness: ServerWindowHarness) {
        Task {
            await loadHermesProfiles(harness: harness)
            guard self.harness === harness else { return }
            if !hermesProfiles.contains(where: { $0.name == activeHermesProfile }) {
                switchHermesProfile(to: HermesProfiles.defaultProfileName)
            }
        }
    }

    /// In-place profile swap: tears the old harness down before swapping
    /// `activeProfileId`, which re-fires `.task` to build a fresh harness. Also
    /// resets the Hermes profile to `default` so a new server never inherits a
    /// possibly-nonexistent named profile (both feed one key, so a single
    /// `.task` fire results).
    private func switchProfile(to newId: UUID) {
        guard newId != currentProfileId else { return }
        recents.record(newId)
        harness?.tearDown()
        harness = nil
        browse = .sessions
        hermesProfiles = []
        activeHermesProfile = HermesProfiles.defaultProfileName
        activeProfileId = newId
    }

    /// In-place Hermes-profile swap. Mirrors `switchProfile`: tears the harness
    /// down (dropping open chats, consistent with a server switch) before
    /// swapping `activeHermesProfile`, which re-fires `.task` to rebuild the
    /// whole window — dashboard, ACP chat, and admin runner — under `-p <name>`.
    private func switchHermesProfile(to name: String) {
        guard name != activeHermesProfile else { return }
        harness?.tearDown()
        harness = nil
        browse = .sessions
        activeHermesProfile = name
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
        // Track this window's foreground state (to gate notifications) and
        // consume a tapped-notification route addressed to this profile.
        .chatNotificationRouting(store: harness.store, profileId: harness.profile.id)
    }

    @ViewBuilder
    private func sidebar(harness: ServerWindowHarness) -> some View {
        List {
            SessionsSidebar(
                store: harness.store,
                profile: harness.profile,
                profiles: directory.allProfiles,
                onSwitchProfile: switchProfile,
                hermesProfiles: hermesProfiles,
                activeHermesProfile: activeHermesProfile,
                onSwitchHermesProfile: switchHermesProfile,
                isLoadingHermesProfiles: hermesProfilesLoading
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dashboardError)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Button("Retry") { harness.retryDashboard() }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                                .help("Reconnect the dashboard")
                        }
                    }
                }
            }

            Section("Browse") {
                browseRow(.sessions, store: harness.store)
                ForEach(sidebarLayout.visibleManageDestinations(), id: \.self) { destination in
                    browseRow(destination, store: harness.store)
                }
            }
        }
        // iPad surfaces a gear to open the editor (no Settings scene there);
        // no-op on macOS.
        .platformSettingsToolbarItem { showingSettings = true }
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
    }

    @ViewBuilder
    private func detail(harness: ServerWindowHarness) -> some View {
        if let selection = harness.store.selection,
           let session = harness.store.openSessions.first(where: { $0.id == selection }),
           session.kind == .tui {
            // TUI tabs render the embedded Hermes terminal (macOS) instead of
            // the ACP `ChatView`; they have no view model.
            platformTUIDetail(tabId: session.id, spec: harness.store.tuiSpec(for: session.id))
                .id(session.id)
                .background { closeTabShortcut(harness: harness) }
        } else if let selection = harness.store.selection,
                  let session = harness.store.openSessions.first(where: { $0.id == selection }),
                  let viewModel = harness.store.viewModel(for: session.id) {
            ChatView(viewModel: viewModel)
                .id(session.id)
                .background { closeTabShortcut(harness: harness) }
        } else {
            BrowseDetailView(
                harness: harness,
                destination: browse ?? .sessions,
                hermesProfiles: hermesProfiles,
                activeHermesProfile: activeHermesProfile,
                onProfilesChanged: { reconcileHermesProfiles(harness: harness) }
            )
        }
    }

    /// ⌘W normally closes the window; when a session tab is selected we hijack
    /// the shortcut to close that tab instead (ACP and TUI alike). Disabled with
    /// no selection so the default `Performs Close` handles the keystroke as
    /// usual. Works on iPad with a hardware keyboard too — no `#if` needed.
    @ViewBuilder
    private func closeTabShortcut(harness: ServerWindowHarness) -> some View {
        Button("Close Session") {
            if let id = harness.store.selection {
                Task { await harness.store.closeTab(id) }
            }
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(harness.store.selection == nil)
        .hidden()
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

    private func browseRow(_ destination: BrowseDestination, store: SessionsStore) -> some View {
        Button {
            store.selection = nil
            browse = destination
        } label: {
            Label(destination.title, systemImage: destination.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(browse == destination && store.selection == nil ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

/// Combined rebuild identity for a window's `.task(id:)`: a change to either
/// the server profile or the active Hermes profile rebuilds the harness.
private struct HarnessKey: Hashable {
    let server: UUID
    let hermes: String
}
