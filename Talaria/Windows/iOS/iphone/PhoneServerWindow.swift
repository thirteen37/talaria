import HermesKit
import SwiftUI

/// Compact iPhone window: a `NavigationStack` chat push with a top toolbar
/// (Browse / All-sessions / Reconnect). Browse opens a modal sheet covering the
/// full manage feature set; Settings is reached via Browse → Settings, and the
/// app's own log console lives under Browse → System → App Logs. iOS-only.
struct PhoneServerWindow: View {
    let profileId: UUID

    @Environment(ProfileDirectory.self) private var directory
    @Environment(RecentServers.self) private var recents
    @Environment(SidebarLayout.self) private var sidebarLayout
    @Environment(NotificationSettings.self) private var notificationSettings
    @State private var harness: ServerWindowHarness?
    /// Window-scoped navigation intent for `EntityLink` taps. Injected into the
    /// content and the Browse sheet; this window observes `pendingFocus` to open
    /// the chat or the Browse sheet seeded to the entity's page.
    @State private var navigator = WindowNavigator()
    @State private var showingSettings = false
    @State private var showingAllSessions = false
    @State private var showingBrowse = false
    /// Optional surface the Browse sheet should open directly on (set by the
    /// bell → Notifications deep link; nil for the plain Browse button).
    @State private var browseDeepLink: BrowseDestination?
    /// Set when the Browse sheet's Settings row is tapped: the sheet dismisses
    /// itself, then this defers opening the body-level Settings sheet until
    /// Browse is fully gone (two sheets can't present at once).
    @State private var pendingSettings = false
    /// Drives the chat push stack. Selecting/creating a session pushes its id;
    /// popping (back-swipe) clears the selection.
    @State private var chatPath: [SessionId] = []
    @State private var activeProfileId: UUID?
    /// Active Hermes profile (`hermes -p <name>`) the whole window is scoped to.
    /// Does not persist — resets to `default` on launch and on every server
    /// switch.
    @State private var activeHermesProfile = HermesProfiles.defaultProfileName
    /// Hermes profiles available on the active server, enumerated after the
    /// dashboard comes online. Drives the sidebar switcher.
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
            } else if directory.profiles.isEmpty {
                // iPhone is remote-only (no bundled local profile), so an empty
                // list is a genuine no-server state. Distinguish it from the
                // brief window where the harness is still building after launch
                // (directory reload in flight) so we don't flash the empty-state
                // CTA over configured servers.
                noServerConfiguredView
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(harness?.profile.name ?? directory.profile(id: currentProfileId)?.name ?? "Hermes")
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
        // Auto-build only when no server is active yet (the no-server empty
        // state), so saving the first server connects without a relaunch.
        .onChange(of: directory.profiles) { _, _ in
            guard harness == nil else { return }
            Task { await rebuildHarness() }
        }
        // Attached at body level so the no-server empty state (which has no
        // harness/sidebar in scope) can still present the Settings sheet.
        .sheet(isPresented: $showingSettings) {
            SettingsTabs(onDismiss: { showingSettings = false })
                .environment(directory)
                .environment(sidebarLayout)
                .environment(notificationSettings)
        }
        .onDisappear {
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
        if UITestFlags.screenshotFixture {
            hermesProfilesLoading = false
            hermesProfiles = [
                HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true),
                HermesProfileInfo(name: "release", isDefault: false),
            ]
            let previous = harness
            let fixture = ServerWindowHarness.makeScreenshotFixture()
            harness = fixture
            previous?.tearDown()
            if UITestFlags.opensScreenshotChat {
                await fixture.openScreenshotSession()
                chatPath = [ScreenshotFixtures.primarySessionID]
            }
            return
        }
        if UITestFlags.mockServer {
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
        harness?.startDashboard()
        // Enumerate the server's Hermes profiles for the sidebar switcher. Kept
        // out of `.task(id:)` (it isn't a rebuild trigger — that would loop).
        if let harness {
            Task { await loadHermesProfiles(harness: harness) }
        } else {
            hermesProfiles = []
        }
    }

    /// Populates `hermesProfiles` for the switcher straight from the dashboard
    /// API. Stays default-only/hidden until the dashboard is online or if the
    /// call fails — no CLI `profile list` fallback, whose decorated table would
    /// leak marker glyphs into the menu. Re-run when `dashboardClient` lands (see
    /// the `.onChange` below) to upgrade the list.
    @MainActor
    private func loadHermesProfiles(harness: ServerWindowHarness) async {
        // Capture the client before the await: only a dashboard-backed load is
        // authoritative. The first client-less load returns default-only and
        // must keep the placeholder up until the dashboard lands.
        let client = harness.dashboardClient
        let profiles = await HermesProfiles.selectorProfiles(client: client)
        // Drop a stale listing if the window rebuilt its harness (server or
        // Hermes-profile switch) while this read was in flight, so it can't
        // overwrite the active harness's profiles with the previous one's.
        // Identity (not profile id) is the right key: a Hermes-profile switch
        // keeps the server id but builds a fresh harness.
        guard self.harness === harness else { return }
        hermesProfiles = profiles
        if client != nil { hermesProfilesLoading = false }
    }

    /// Re-runs the Hermes-profile listing after a Profiles mutation so the
    /// switcher reflects the change. If the active `-p <name>` was renamed or
    /// deleted, falls back to `default` so the window isn't scoped to a dead
    /// profile.
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

    /// In-place server swap. Resets the Hermes profile to `default` so a new
    /// server never inherits a possibly-nonexistent named profile (both feed
    /// one key, so a single `.task` fire results).
    private func switchProfile(to newId: UUID) {
        guard newId != currentProfileId else { return }
        recents.record(newId)
        harness?.tearDown()
        harness = nil
        hermesProfiles = []
        activeHermesProfile = HermesProfiles.defaultProfileName
        activeProfileId = newId
    }

    /// In-place Hermes-profile swap: tears the harness down (dropping open
    /// chats) and rebuilds the whole window under `-p <name>`.
    private func switchHermesProfile(to name: String) {
        guard name != activeHermesProfile else { return }
        harness?.tearDown()
        harness = nil
        activeHermesProfile = name
    }

    /// Routes an `EntityLink` tap. A `.session` ref opens the chat (and clears
    /// the focus); any other ref opens the Browse sheet seeded to the entity's
    /// page, leaving `pendingFocus` set for the target page to consume. When the
    /// sheet is already open, its own observer re-navigates the stack.
    private func routeFocus(_ ref: EntityRef?, harness: ServerWindowHarness) {
        guard let ref else { return }
        if let id = ref.sessionId {
            harness.store.selection = id
            navigator.pendingFocus = nil
        } else if !showingBrowse {
            browseDeepLink = ref.destination
            showingBrowse = true
        }
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        // Explicit push stack: the collapsed NavigationSplitView's programmatic
        // detail push proved unreliable, so on iPhone we drive a
        // NavigationStack directly from the selection.
        NavigationStack(path: $chatPath) {
            sidebar(harness: harness)
                .navigationTitle(harness.profile.name)
                .navigationDestination(for: SessionId.self) { id in
                    chatDestination(harness: harness, id: id)
                }
        }
        // Window-scoped navigation for EntityLink taps in chat + browse surfaces.
        .environment(navigator)
        .onChange(of: navigator.pendingFocus) { _, ref in
            routeFocus(ref, harness: harness)
        }
        .onChange(of: harness.store.selection) { _, newValue in
            chatPath = newValue.map { [$0] } ?? []
        }
        .onChange(of: chatPath) { _, path in
            // Back-swipe empties the path — clear the selection so re-tapping
            // the same session re-pushes the chat.
            if path.isEmpty, harness.store.selection != nil {
                harness.store.selection = nil
            }
        }
        .alert(
            "Trust this server?",
            isPresented: Binding(
                get: { harness.hostKeyCoordinator?.pending != nil },
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
        // Full-width banner strip across the top of the window: bridges
        // session/dashboard errors + the web-UI progress note from the sidebar.
        // iPhone has no side-by-side sidebar, so hosting the strip at the
        // NavigationStack root keeps it correctly full-width (the bridge no
        // longer hosts it).
        .bannerHost(harness.banners)
        .bridgeWindowBanners(harness: harness)
    }

    @ViewBuilder
    private func chatDestination(harness: ServerWindowHarness, id: SessionId) -> some View {
        if let session = harness.store.openSessions.first(where: { $0.id == id }),
           let viewModel = harness.store.viewModel(for: session.id) {
            ChatView(viewModel: viewModel)
                .id(session.id)
        } else {
            ContentUnavailableView("Session unavailable", systemImage: "bubble.left.and.bubble.right")
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
                hermesProfiles: hermesProfiles,
                activeHermesProfile: activeHermesProfile,
                onSwitchHermesProfile: switchHermesProfile,
                isLoadingHermesProfiles: hermesProfilesLoading
            )

            // Connection / session errors and the "Building web UI…" progress
            // note no longer render here — they're bridged to the full-width
            // top-of-window strip (see `bridgeWindowBanners` in `content`).
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    browseDeepLink = nil
                    showingBrowse = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("Browse")
                .help("Browse servers and settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAllSessions = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("All sessions")
                .help("View all sessions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    harness.reconnectDashboard()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reconnect dashboard")
                .help("Reconnect the Hermes dashboard")
            }
        }
        // Settings is reached via Browse → Settings: the row dismisses Browse,
        // then `onDismiss` opens the body-level Settings sheet once Browse is
        // gone (two sheets can't be presented at the same time).
        .sheet(isPresented: $showingBrowse, onDismiss: {
            if pendingSettings {
                pendingSettings = false
                showingSettings = true
            }
        }) {
            PhoneBrowseSheet(
                harness: harness,
                hermesProfiles: hermesProfiles,
                activeHermesProfile: activeHermesProfile,
                onProfilesChanged: { reconcileHermesProfiles(harness: harness) },
                initial: browseDeepLink,
                onOpenSettings: {
                    pendingSettings = true
                    showingBrowse = false
                },
                onDismiss: { showingBrowse = false }
            )
            .environment(sidebarLayout)
            .environment(navigator)
        }
        .sheet(isPresented: $showingAllSessions) {
            NavigationStack {
                SessionsBrowser(
                    store: harness.store,
                    client: harness.dashboardClient,
                    onOpen: { showingAllSessions = false }
                )
                .navigationTitle("Sessions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showingAllSessions = false }
                            .help("Close all sessions")
                    }
                }
            }
        }
    }
}

/// Combined rebuild identity for the window's `.task(id:)`: a change to either
/// the server profile or the active Hermes profile rebuilds the harness.
private struct HarnessKey: Hashable {
    let server: UUID
    let hermes: String
}
