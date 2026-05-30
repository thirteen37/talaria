import HermesKit
import SwiftUI

/// Compact iPhone window: a `NavigationStack` chat push with a top toolbar
/// (Browse / All-sessions / Logs). Browse opens a modal sheet covering the full
/// manage feature set; Settings is reached via Browse → Settings. iOS-only.
struct PhoneServerWindow: View {
    let profileId: UUID

    @Environment(ProfileDirectory.self) private var directory
    @Environment(RecentServers.self) private var recents
    @State private var harness: ServerWindowHarness?
    @State private var showingSettings = false
    @State private var showingAllSessions = false
    @State private var showingLogs = false
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
        // Auto-build only when no server is active yet (the no-server empty
        // state), so saving the first server connects without a relaunch.
        .onChange(of: directory.profiles) { _, _ in
            guard harness == nil else { return }
            Task { await rebuildHarness() }
        }
        // Attached at body level so the no-server empty state (which has no
        // harness/sidebar in scope) can still present the Settings sheet.
        .sheet(isPresented: $showingSettings) {
            ProfileEditorRoot(onDismiss: { showingSettings = false })
                .environment(directory)
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
        if UITestFlags.mockServer {
            let previous = harness
            harness = ServerWindowHarness.makeMock()
            previous?.tearDown()
            return
        }
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

    /// Populates `hermesProfiles` for the switcher. Prefers the dashboard API;
    /// falls back to the CLI `profile list`; degrades to `[default]`.
    @MainActor
    private func loadHermesProfiles(harness: ServerWindowHarness) async {
        // Drop a stale listing if the window rebuilt its harness (server or
        // Hermes-profile switch) while this read was in flight, so it can't
        // overwrite the active harness's profiles with the previous one's.
        // Identity (not profile id) is the right key: a Hermes-profile switch
        // keeps the server id but builds a fresh harness.
        func apply(_ profiles: [HermesProfileInfo]) {
            guard self.harness === harness else { return }
            hermesProfiles = profiles
        }
        if let client = harness.dashboardClient {
            do {
                let list = try await client.listProfiles()
                apply(list.map {
                    HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, model: $0.model)
                })
                return
            } catch {
                // Fall through to the CLI source.
            }
        }
        if let runner = harness.store.adminRunner {
            do {
                apply(try await HermesProfiles.list(runner: runner))
                return
            } catch {
                // Fall through to the default-only degrade.
            }
        }
        apply([HermesProfileInfo(name: HermesProfiles.defaultProfileName, isDefault: true, status: nil)])
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
                notifications: harness.notifications,
                // Bell opens the Browse sheet directly on Notifications.
                onOpenNotifications: {
                    browseDeepLink = .notifications
                    showingBrowse = true
                }
            )

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
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAllSessions = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("All sessions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingLogs = true
                } label: {
                    Image(systemName: "ladybug")
                }
                .accessibilityLabel("Logs")
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
        }
        .sheet(isPresented: $showingLogs) {
            LogConsoleView(onDismiss: { showingLogs = false })
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
