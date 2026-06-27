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
    /// Compact width = the NavigationSplitView is collapsed to a single column
    /// (iPad Slide Over / narrow Split View; always `.regular` on macOS). Drives
    /// where the banner strip is hosted — see `content`.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Cold-relaunch restoration store. Injected on iOS/iPad (where the app can be
    /// terminated while suspended); nil on macOS — the optional form keeps the
    /// shared save/restore wiring inert there (desktop windows aren't killed).
    @Environment(WindowRestorationStore.self) private var restoration: WindowRestorationStore?
    @State private var controller = ServerWindowController()
    @State private var browse: BrowseDestination? = UITestFlags.screenshotBrowseDestination ?? .sessions
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
    /// Window-scoped navigation intent for `EntityLink` taps. Injected into the
    /// content so chat + browse surfaces can route to an entity's page; this
    /// window observes `pendingFocus` to switch pages, the target page clears it.
    @State private var navigator = WindowNavigator()
    @State private var showingSettings = false
    /// Sidebar visibility, driven by our custom toggle. We manage it ourselves
    /// (rather than letting the system own the sidebar button) so the toggle can
    /// carry a notification badge that stays visible when the sidebar collapses.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private var currentProfileId: UUID { controller.currentProfileId(default: profileId) }

    /// Combined rebuild identity: a change to either the server or the Hermes
    /// profile tears the harness down and rebuilds it.
    private var harnessKey: ServerWindowHarnessKey { controller.harnessKey(default: profileId) }

    var body: some View {
        Group {
            if let harness = controller.harness {
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
        .navigationTitle(controller.harness?.profile.name ?? directory.profile(id: currentProfileId)?.name ?? "Hermes")
        .platformWindowSubtitle(subtitle(for: controller.harness?.profile ?? directory.profile(id: currentProfileId)))
        .task(id: harnessKey) {
            await controller.rebuild(defaultProfileId: profileId, directory: directory)
        }
        // The dashboard comes online async, after `rebuildHarness` already ran
        // its first (client-less) profile load. Re-run once it lands so the
        // switcher upgrades from default-only to the live dashboard list,
        // mirroring the config editor's dashboard-ready re-load.
        .onChange(of: controller.harness?.dashboardClient != nil) { _, hasClient in
            guard hasClient, let harness = controller.harness else { return }
            Task { await controller.loadHermesProfiles(harness: harness) }
            // Sessions resume over the dashboard, so a cold-launch restore can
            // only run once it's live. No-op on macOS (restoration store is nil).
            restoreIfNeeded(harness: harness)
        }
        // Last reliable hook before iOS may terminate the suspended app: persist
        // the navigation + open chats. No-op on macOS (the seam is a no-op there).
        .onEnterBackground {
            if let harness = controller.harness { captureRestoration(harness: harness) }
        }
        // Clear the loading placeholder if the dashboard fails to spawn: the
        // client stays nil so the success path never fires, leaving the spinner
        // up forever otherwise.
        .onChange(of: controller.harness?.dashboardError != nil) { _, hasError in
            if hasError { controller.hermesProfilesLoading = false }
        }
        // iPad: saving the first server (or a profile mutation while no harness
        // is live) connects without a relaunch. Harmless on macOS, which builds
        // a harness eagerly via the local fallback. Rebuilding while a harness
        // is live would drop the in-progress chat, so it's skipped then.
        .onChange(of: directory.profiles) { _, _ in
            guard controller.harness == nil else { return }
            Task { await controller.rebuild(defaultProfileId: profileId, directory: directory) }
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
            controller.tearDown()
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
    private func reconcileHermesProfiles(harness: ServerWindowHarness) {
        controller.reconcileHermesProfiles(harness: harness)
    }

    /// In-place profile swap: tears the old harness down before swapping
    /// `activeProfileId`, which re-fires `.task` to build a fresh harness. Also
    /// resets the Hermes profile to `default` so a new server never inherits a
    /// possibly-nonexistent named profile (both feed one key, so a single
    /// `.task` fire results).
    private func switchProfile(to newId: UUID) {
        if controller.switchProfile(to: newId, launchProfileId: profileId, recents: recents) {
            browse = .sessions
        }
    }

    /// In-place Hermes-profile swap. Mirrors `switchProfile`: tears the harness
    /// down (dropping open chats, consistent with a server switch) before
    /// swapping `activeHermesProfile`, which re-fires `.task` to rebuild the
    /// whole window — dashboard, chat, and admin runner — under `-p <name>`.
    private func switchHermesProfile(to name: String) {
        if controller.switchHermesProfile(to: name) {
            browse = .sessions
        }
    }

    /// Routes an `EntityLink` tap. A `.session` ref opens the chat (and clears
    /// the focus); any other ref switches the detail column to the entity's
    /// browse page and leaves `pendingFocus` set for the target page to consume
    /// (select the row, then clear).
    private func routeFocus(_ ref: EntityRef?, harness: ServerWindowHarness) {
        guard let ref else { return }
        if let id = ref.sessionId {
            // Open the session (not just select) so a deep link to a session that
            // isn't an open tab — e.g. a historical session from a Hindsight
            // `session:`/`parent:` tag — actually surfaces its chat instead of
            // dropping to the sessions list.
            harness.store.openSession(id: id)
            navigator.pendingFocus = nil
        } else {
            harness.store.selection = nil
            browse = ref.destination
        }
    }

    // MARK: - Cold-relaunch restoration (iOS/iPad; inert on macOS)

    /// Marks that the user navigated before the restore ran, permanently
    /// cancelling it. A no-op once the restore has already run — restore's own
    /// writes must not trip it. Used for the browse/settings hooks, which the
    /// restore only touches synchronously up front (never during the async
    /// re-open). (On macOS `didRestore` never flips, but the latch is harmless:
    /// `captureRestoration`/`restoreIfNeeded` are inert with a nil store.)
    private func noteUserAction() {
        if !didRestore { userHasActed = true }
    }

    /// Latches `userHasActed` for a user-driven selection change so a pending restore
    /// can't overwrite it. Pre-restore, any selection is the user. During the
    /// restore's async re-open, `reopenSessions` opens tabs *without* selecting, so a
    /// non-nil selection can only be a live user tap — even of a previously-open
    /// session. The restore's own final selection write happens after `isRestoring`
    /// clears, so it never trips this. (Inert on macOS, where restore never runs.)
    private func noteSelectionChange(_ newValue: SessionId?) {
        if (!didRestore || isRestoring), newValue != nil {
            userHasActed = true
        }
    }

    /// Persists the current navigation + open chats for this window's profile.
    /// Inert on macOS (nil store) and under UI-test fixtures; skipped while a
    /// restore is applying so half-restored state isn't written.
    ///
    /// Gated on `didRestore`: nothing is captured until the restore has run (or was
    /// definitively skipped — `restoreIfNeeded` sets `didRestore` whenever it
    /// proceeds or finds no snapshot). Before that, the window holds the pre-restore
    /// baseline (no chats open until the dashboard connects and restore re-opens
    /// them), so persisting it would clobber the saved snapshot with empty state —
    /// including the cases where the dashboard never connects (offline) or the user
    /// navigates before it does (which cancels restore without setting `didRestore`).
    /// On macOS `didRestore` never flips (the nil store makes this inert anyway).
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
            // The Browse page is "focused" only when no chat is selected; iPad has
            // no nested Browse stack, so `browseSubPath` stays empty.
            browse: harness.store.selection == nil ? browse?.rawValue : nil,
            browseSubPath: [],
            sheet: showingSettings ? "settings" : nil
        )
        restoration.record(snapshot, for: harness.profile.id)
    }

    /// Restores the saved navigation and re-opens the live chats after a cold
    /// relaunch. Runs at most once per window, only when the dashboard is live and
    /// no tabs are open (a warm reconnect keeps its tabs and is handled by
    /// `recoverLiveSessions`), and never after the user has already navigated.
    @MainActor
    private func restoreIfNeeded(harness: ServerWindowHarness) {
        guard let restoration,
              !UITestFlags.anyFixtureActive,
              !didRestore, !userHasActed,
              harness.dashboardClient != nil,
              harness.store.openSessions.isEmpty,
              controller.harness === harness,
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
        if let raw = snapshot.browse, let dest = BrowseDestination(rawValue: raw) {
            browse = dest
        }
        if snapshot.sheet == "settings" { showingSettings = true }

        // Then re-open the live chats over the dashboard, and apply the recorded
        // selection once — after `isRestoring` clears, so the selection onChange
        // doesn't mistake restore's own write for a user tap.
        Task {
            let reopened = await controller.reopenSessions(
                harness: harness,
                snapshot: snapshot,
                shouldContinue: { !userHasActed }
            )
            isRestoring = false
            if let reopened, !userHasActed, controller.harness === harness {
                harness.store.selection = WindowRestoration.resolvedSelection(
                    recorded: snapshot.selection,
                    reopened: reopened
                )
            }
            // Don't capture here: the restored state already equals the snapshot on
            // disk, so a capture would be a skip-if-equal no-op. Genuine navigation
            // re-captures from here on.
        }
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(harness: harness)
                // In compact width the split view collapses to a single column
                // and shows the sidebar first (no detail on screen), so the
                // detail-pane host below can't surface startup/connection
                // banners while the user is on the sidebar. Host them here in
                // that case only — and never in regular width, where it would
                // reintroduce the over-the-sidebar overlap this layout fixes.
                .bannerHost(harness.banners, active: horizontalSizeClass == .compact)
        } detail: {
            detail(harness: harness)
                // Regular width: host the strip over the detail pane only, so
                // the red error / green success strip never lands on top of the
                // sidebar header. (In compact, only one column is on screen at a
                // time, so the sidebar host above never double-shows.) The
                // bridge below publishes the center this reads.
                .bannerHost(harness.banners)
        }
        // Window-scoped navigation for EntityLink taps in chat + browse surfaces.
        .environment(navigator)
        .onChange(of: navigator.pendingFocus) { _, ref in
            routeFocus(ref, harness: harness)
        }
        // Cold-relaunch capture + the user-acted latch. All no-ops on macOS, where
        // the restoration store is nil so `captureRestoration` returns immediately.
        .onChange(of: harness.store.selection) { _, newValue in
            noteSelectionChange(newValue)
            captureRestoration(harness: harness)
        }
        .onChange(of: browse) { _, _ in
            noteUserAction()
            captureRestoration(harness: harness)
        }
        .onChange(of: harness.store.openSessions) { _, _ in
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
        .chatNotificationRouting(harness: harness)
        // Bridges session/dashboard errors + the web-UI progress note from the
        // sidebar into the center, and publishes the center so detail surfaces
        // emit save successes here. The visible strip is hosted over the detail
        // pane only (see `bannerHost` above) so it never covers the sidebar.
        .bridgeWindowBanners(harness: harness)
        // Publish this window's actions to the menu bar (macOS) / hardware-keyboard
        // menu (iPad). Recomputed each body eval, so it tracks state; the closures
        // mutate `@State` / call the switch methods exactly as the sidebar does.
        // The frontmost window wins via `.focusedSceneValue`.
        .focusedSceneValue(\.windowMenu, WindowMenuModel(
            browseDestinations: [.sessions] + sidebarLayout.visibleManageDestinations(),
            currentBrowse: harness.store.selection == nil ? (browse ?? .sessions) : nil,
            selectBrowse: { dest in harness.store.selection = nil; browse = dest },
            isOpeningSession: harness.store.isOpening,
            newSession: { Task { await harness.store.openNew() } },
            serverProfiles: directory.allProfiles,
            currentServerId: currentProfileId,
            switchServer: { id in switchProfile(to: id) },
            hermesProfiles: controller.hermesProfiles,
            activeHermesProfile: controller.activeHermesProfile,
            isLoadingHermesProfiles: controller.hermesProfilesLoading,
            switchHermes: { name in switchHermesProfile(to: name) }))
    }

    @ViewBuilder
    private func sidebar(harness: ServerWindowHarness) -> some View {
        List {
            SessionsSidebar(
                store: harness.store,
                profile: harness.profile,
                profiles: directory.allProfiles,
                onSwitchProfile: switchProfile,
                hermesProfiles: controller.hermesProfiles,
                activeHermesProfile: controller.activeHermesProfile,
                onSwitchHermesProfile: switchHermesProfile,
                isLoadingHermesProfiles: controller.hermesProfilesLoading,
                // The split-view sidebar is translucent (glass on iPad, sidebar
                // material on macOS) and hides its grouped backdrop below, so
                // rows render `.clear` to show it through.
                translucentRows: true
            )
                .onChange(of: harness.store.selection) { _, newValue in
                    if newValue != nil {
                        browse = nil
                    }
                }

            // Connection / session errors and the "Building web UI…" progress
            // note no longer render here — they're bridged to the full-width
            // top-of-window strip (see `bridgeWindowBanners` in `content`).

            Section("Browse") {
                browseRow(.sessions, store: harness.store)
                ForEach(sidebarLayout.visibleManageDestinations(), id: \.self) { destination in
                    browseRow(destination, store: harness.store)
                }
            }
        }
        #if os(iOS)
        // Drop the grouped List's opaque scroll/section backdrop so the glass
        // sidebar shows through; pairs with the `.clear` row backgrounds below.
        .scrollContentBackground(.hidden)
        #endif
        // iPad surfaces a gear to open the editor (no Settings scene there);
        // no-op on macOS.
        .platformSettingsToolbarItem { showingSettings = true }
        // Always-available reconnect: a live dashboard can wedge (dropped ssh
        // forward, crashed/restarted remote) while still reporting "connected",
        // and the error-banner Retry only shows on a *failed* acquire.
        .toolbar {
            // Aggregate "needs you" badge: visible from any screen in the window
            // (even with the sidebar collapsed or a non-chat surface open) so a
            // background session blocked on a prompt doesn't go unnoticed. Tapping
            // jumps to the first waiting session.
            let awaiting = harness.store.sessionsAwaitingInput
            if let firstAwaiting = awaiting.first {
                ToolbarItem {
                    let count = awaiting.count
                    Button { harness.store.selection = firstAwaiting } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bell.badge.fill")
                            if count > 1 { Text("\(count)") }
                        }
                    }
                    .accessibilityLabel(
                        count > 1
                            ? "\(count) sessions waiting for your input"
                            : "A session is waiting for your input"
                    )
                    .help("A session is waiting for your input")
                }
            }
            ToolbarItem {
                Button { harness.reconnectDashboard() } label: {
                    Label("Reconnect Dashboard", systemImage: "arrow.clockwise")
                }
                .help("Reconnect the Hermes dashboard")
            }
        }
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
            ChatView(viewModel: viewModel, store: harness.store)
                .id(session.id)
                .background { closeTabShortcut(harness: harness) }
        } else {
            BrowseDetailView(
                harness: harness,
                destination: browse ?? .sessions,
                hermesProfiles: controller.hermesProfiles,
                activeHermesProfile: controller.activeHermesProfile,
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
            HStack(spacing: 6) {
                Label(destination.title, systemImage: destination.systemImage)
                Spacer(minLength: 0)
                if showsUpdateBadge(for: destination) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Hermes update available")
                        .help("Hermes update available")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(browse == destination && store.selection == nil ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    /// The System row carries a pending-Hermes-update indicator, driven live by
    /// the window-scoped ``UpdatesHarness`` (`@Observable`, so background checks
    /// landing flip the dot without a manual refresh).
    private func showsUpdateBadge(for destination: BrowseDestination) -> Bool {
        destination == .system && controller.harness?.updates?.status?.available == true
    }
}
