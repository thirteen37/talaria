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
    /// Cold-relaunch restoration store (injected on iOS). Reads the saved
    /// navigation snapshot once the dashboard is live, and is written on
    /// backgrounding + each navigation change.
    @Environment(WindowRestorationStore.self) private var restoration: WindowRestorationStore?
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
    /// The Browse sheet's nested stack, mirrored here so it can be captured for
    /// restoration; `[]` while the sheet is closed or on its root list.
    @State private var browseSubPath: [BrowseDestination] = []
    /// Transient seed for the Browse sheet on a cold-relaunch restore — the saved
    /// nested stack to re-open into. Cleared once the sheet is dismissed.
    @State private var restoredBrowsePath: [BrowseDestination] = []
    /// Cold-relaunch restore runs at most once per window lifetime. (Window-scoped
    /// `@State`, so an in-window profile switch that rebuilds the harness does not
    /// re-restore — v1 restores the launch profile only.)
    @State private var didRestore = false
    /// Latches when the user navigates before the restore runs, permanently
    /// cancelling it so a disk value never clobbers a live intent.
    @State private var userHasActed = false
    /// True while a restore is applying (sync nav + async re-open), so the capture
    /// hooks don't persist half-restored state and the latch ignores restore's own
    /// writes.
    @State private var isRestoring = false
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
            // Sessions resume over the dashboard, so a cold-launch restore can
            // only run once it's live. Reuses this same dashboard-ready edge.
            restoreIfNeeded(harness: harness)
        }
        // Last reliable hook before iOS may terminate the suspended app: persist
        // the navigation + open chats so a cold relaunch lands back in place.
        .onEnterBackground {
            if let harness { captureRestoration(harness: harness) }
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

    // MARK: - Cold-relaunch restoration

    /// Nested stack the Browse sheet opens into: a deep link wins, otherwise the
    /// restored sub-path (empty for a plain Browse tap → the root list).
    private var browseInitialPath: [BrowseDestination] {
        if let browseDeepLink { return [browseDeepLink] }
        return restoredBrowsePath
    }

    /// The presented sheet for the snapshot's `sheet` field.
    private var currentSheet: String? {
        if showingSettings { return "settings" }
        if showingBrowse { return "browse" }
        if showingAllSessions { return "allSessions" }
        return nil
    }

    /// Marks that the user navigated before the restore ran, permanently
    /// cancelling it (a live intent must always beat the disk value). A no-op once
    /// the restore has already run — restore's own writes must not trip it. Used for
    /// the sheet hooks, which the restore only touches synchronously up front (never
    /// during the async re-open), so `!didRestore` is the right gate there.
    private func noteUserAction() {
        if !didRestore { userHasActed = true }
    }

    /// Latches `userHasActed` for a user-driven selection change so a pending restore
    /// can't overwrite it. Pre-restore, any selection is the user. During the
    /// restore's async re-open, `reopenSessions` opens tabs *without* selecting
    /// (`select: false`), so a non-nil selection can only be a live user tap — even
    /// of a previously-open session. The restore's own final selection write happens
    /// after `isRestoring` clears, so it never trips this.
    private func noteSelectionChange(_ newValue: SessionId?) {
        if (!didRestore || isRestoring), newValue != nil {
            userHasActed = true
        }
    }

    /// Persists the current navigation + open chats for this window's profile.
    /// Best-effort and idempotent (the store skips equal snapshots); skipped while
    /// a restore is applying so half-restored state isn't written, and inert under
    /// UI-test fixtures.
    ///
    /// Gated on `didRestore`: nothing is captured until the restore has run (or was
    /// definitively skipped — `restoreIfNeeded` sets `didRestore` whenever it
    /// proceeds or finds no snapshot). Before that, the window holds the pre-restore
    /// baseline (no chats can be open until the dashboard connects and restore
    /// re-opens them), so persisting it would clobber the saved snapshot with empty
    /// state — including the cases where the dashboard never connects (offline) or
    /// the user navigates before it does (which cancels restore without setting
    /// `didRestore`). The saved snapshot is preserved for the next launch instead.
    @MainActor
    private func captureRestoration(harness: ServerWindowHarness) {
        guard let restoration, !UITestFlags.anyFixtureActive, !isRestoring, didRestore else { return }
        let liveTabs = harness.store.openSessions.filter { session in
            session.kind == .acp && harness.store.viewModel(for: session.id)?.isReadOnly == false
        }
        var openTitles: [SessionId: String] = [:]
        for tab in liveTabs {
            if let title = tab.title, !title.isEmpty { openTitles[tab.id] = title }
        }
        let snapshot = WindowRestorationSnapshot(
            openSessionIds: liveTabs.map(\.id),
            openTitles: openTitles,
            selection: harness.store.selection,
            // iPhone keeps chat as its root stack; Browse lives in the sheet, so
            // its depth rides `browseSubPath`, not the `browse` field.
            browse: nil,
            browseSubPath: browseSubPath.map(\.rawValue),
            sheet: currentSheet
        )
        restoration.record(snapshot, for: harness.profile.id)
    }

    /// Restores the saved navigation and re-opens the live chats after a cold
    /// relaunch. Runs at most once per window, only when the dashboard is live
    /// and no tabs are open (a warm reconnect keeps its tabs and is handled by
    /// `recoverLiveSessions`), and never after the user has already navigated.
    @MainActor
    private func restoreIfNeeded(harness: ServerWindowHarness) {
        guard let restoration,
              !UITestFlags.anyFixtureActive,
              !didRestore, !userHasActed,
              harness.dashboardClient != nil,
              harness.store.openSessions.isEmpty,
              self.harness === harness,
              harness.hostKeyCoordinator?.pending == nil,
              directory.profile(id: harness.profile.id) != nil
        else { return }
        guard let snapshot = restoration.snapshot(for: harness.profile.id) else {
            didRestore = true
            return
        }
        didRestore = true
        isRestoring = true

        // Navigation first, synchronously, so the user lands in place immediately.
        restoredBrowsePath = snapshot.browseSubPath.compactMap(BrowseDestination.init(rawValue:))
        applySheet(snapshot.sheet)

        // Then re-open the live chats over the dashboard, and apply the recorded
        // selection once — after `isRestoring` clears, so the selection onChange
        // doesn't mistake restore's own write for a user tap.
        Task {
            let reopened = await reopenSessions(harness: harness, snapshot: snapshot)
            isRestoring = false
            if let reopened, !userHasActed, self.harness === harness {
                harness.store.selection = WindowRestoration.resolvedSelection(
                    recorded: snapshot.selection,
                    reopened: reopened
                )
            }
            // Don't capture here: the restored state already equals the snapshot on
            // disk (so a capture would be a skip-if-equal no-op), and capturing now
            // could race the Browse sheet's `onPathChange` and momentarily persist an
            // empty sub-path. Genuine navigation — including the sheet seeding its
            // nested stack — re-captures from here on.
        }
    }

    @MainActor
    private func applySheet(_ sheet: String?) {
        switch sheet {
        case "browse": showingBrowse = true
        case "allSessions": showingAllSessions = true
        case "settings": showingSettings = true
        default: break
        }
    }

    /// Re-opens each recorded session via `reopenForRestore` (resolves cwd, seeds
    /// history, **and skips a server-deleted / unpersisted id silently** — no error
    /// banner) **without selecting** — the caller applies the recorded selection
    /// once at the end. Returns the ids that re-opened, or `nil` if the restore was
    /// abandoned (the user acted, via the `noteSelectionChange` latch, or the harness
    /// was replaced). Because the selection stays still during the loop, a user tap
    /// mid-re-open is detected and bails here rather than being silently overwritten.
    @MainActor
    private func reopenSessions(harness: ServerWindowHarness, snapshot: WindowRestorationSnapshot) async -> [SessionId]? {
        var reopened: [SessionId] = []
        for id in snapshot.openSessionIds {
            guard !userHasActed, self.harness === harness else { return nil }
            if await harness.store.reopenForRestore(id: id, title: snapshot.openTitles[id] ?? "") {
                reopened.append(id)
            }
        }
        guard !userHasActed, self.harness === harness else { return nil }
        return reopened
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        // Explicit push stack: the collapsed NavigationSplitView's programmatic
        // detail push proved unreliable, so on iPhone we drive a
        // NavigationStack directly from the selection.
        NavigationStack(path: $chatPath) {
            sidebar(harness: harness)
                .navigationTitle(harness.profile.name)
                .bannerHost(harness.banners)
                .navigationDestination(for: SessionId.self) { id in
                    chatDestination(harness: harness, id: id)
                        .bannerHost(harness.banners)
                }
        }
        // Window-scoped navigation for EntityLink taps in chat + browse surfaces.
        .environment(navigator)
        .onChange(of: navigator.pendingFocus) { _, ref in
            routeFocus(ref, harness: harness)
        }
        .onChange(of: harness.store.selection) { _, newValue in
            chatPath = newValue.map { [$0] } ?? []
            noteSelectionChange(newValue)
            captureRestoration(harness: harness)
        }
        .onChange(of: chatPath) { _, path in
            // Back-swipe empties the path — clear the selection so re-tapping
            // the same session re-pushes the chat.
            if path.isEmpty, harness.store.selection != nil {
                harness.store.selection = nil
            }
        }
        // Persist open-tab changes (a new chat, a closed tab) for restoration.
        .onChange(of: harness.store.openSessions) { _, _ in
            captureRestoration(harness: harness)
        }
        // Sheet visibility feeds the snapshot's `sheet` field; opening a sheet
        // before the restore runs counts as a user action that cancels it. A
        // closing Browse sheet drops its restored seed + nested path.
        .onChange(of: showingBrowse) { _, isOpen in
            if isOpen { noteUserAction() } else {
                restoredBrowsePath = []
                browseSubPath = []
            }
            captureRestoration(harness: harness)
        }
        .onChange(of: showingAllSessions) { _, isOpen in
            if isOpen { noteUserAction() }
            captureRestoration(harness: harness)
        }
        .onChange(of: showingSettings) { _, isOpen in
            if isOpen { noteUserAction() }
            captureRestoration(harness: harness)
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
        .chatNotificationRouting(harness: harness)
        // Full-width banner strip across the top of the window: bridges
        // session/dashboard errors + the web-UI progress note from the sidebar.
        // The visible strip is hosted *inside* the NavigationStack on each
        // on-screen view (the root list and the pushed chat) so its top
        // safe-area inset lands below that view's navigation bar instead of
        // over the toolbar buttons. Only the on-screen view's inset renders;
        // the strip is still full-width because the List / chat fill the column.
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                initialPath: browseInitialPath,
                onPathChange: { newPath in
                    browseSubPath = newPath
                    captureRestoration(harness: harness)
                },
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
