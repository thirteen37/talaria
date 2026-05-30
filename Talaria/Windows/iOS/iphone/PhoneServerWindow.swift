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

    private var currentProfileId: UUID { activeProfileId ?? profileId }

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
        .task(id: currentProfileId) {
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
            harness = ServerWindowHarness.make(profile: profile)
        } else {
            harness = nil
        }
        previous?.tearDown()
        harness?.startDashboard()
    }

    private func switchProfile(to newId: UUID) {
        guard newId != currentProfileId else { return }
        recents.record(newId)
        harness?.tearDown()
        harness = nil
        activeProfileId = newId
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
