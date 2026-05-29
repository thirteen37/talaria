import HermesKit
import SwiftUI

enum BrowseDestination: Hashable {
    case sessions
    case skills
    case tools
    case cron
    case logs
    case doctor
    case updates
}

struct ServerWindow: View {
    let profileId: UUID

    @Environment(ProfileDirectory.self) private var directory
    @State private var harness: ServerWindowHarness?
    @State private var browse: BrowseDestination? = .sessions
    @State private var showingSettings = false
    @State private var showingAllSessions = false
    @State private var showingLogs = false
    /// Drives the iPhone chat push stack. Selecting/creating a session pushes
    /// its id; popping (back-swipe) clears the selection. iPad/macOS use the
    /// NavigationSplitView's detail column instead and ignore this.
    @State private var chatPath: [SessionId] = []

    var body: some View {
        Group {
            if let harness {
                content(harness: harness)
                    .task(id: harness.snapshot?.profile.id) {
                        await observeSnapshot(harness)
                    }
            } else if Idiom.isPhone {
                noServerConfiguredView
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(harness?.profile.name ?? "Hermes")
        .task(id: profileId) {
            await rebuildHarness()
        }
        #if os(iOS)
        // React when servers are added/removed/edited so a freshly saved
        // server becomes the active one without an app relaunch.
        .onChange(of: directory.profiles) { _, _ in
            Task { await rebuildHarness() }
        }
        // Attached at body level so the no-server empty state (which has no
        // harness/sidebar in scope) can still present the Settings sheet.
        .sheet(isPresented: $showingSettings) {
            ProfileEditor(onDismiss: { showingSettings = false })
                .environment(directory)
        }
        #endif
        .onDisappear {
            // Cancel the window-scoped log tailer (and any future
            // long-lived per-window tasks) when the window closes. Without
            // this an SSH profile leaks its `ssh tail -F` subprocess for
            // every closed window that ever visited the Logs view.
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

    /// Resolves the requested server (or first available SSH server on iOS)
    /// and rebuilds the per-window harness. Called from `.task(id:)` on
    /// profile changes and from `.onChange` on directory mutations.
    @MainActor
    private func rebuildHarness() async {
        if UITestFlags.mockServer {
            // UI-test mode: bypass SSH entirely with an in-process ACP server
            // so navigation + chat can be exercised on the simulator.
            let previous = harness
            harness = ServerWindowHarness.makeMock()
            previous?.tearDown()
            return
        }
        await directory.reload()
        AppLog.general.info("rebuildHarness: \(directory.profiles.count) profile(s) configured")
        #if os(iOS)
        // iOS can't run local hermes, so never fall back to the bundled
        // local server. Prefer the requested server when it's a real SSH
        // entry; otherwise pick the first persisted server. With none
        // configured, leave the harness nil so the body renders the
        // no-server empty state.
        let resolved: ServerProfile?
        if let p = directory.profile(id: profileId), p.kind != .local {
            resolved = p
        } else {
            resolved = directory.profiles.first
        }
        let previous = harness
        if let profile = resolved {
            harness = ServerWindowHarness.make(profile: profile)
        } else {
            harness = nil
        }
        previous?.tearDown()
        #else
        let profile = directory.profile(id: profileId) ?? ProfileDirectory.localProfile
        harness = ServerWindowHarness.make(profile: profile)
        #endif
    }

    /// Opens / replaces / closes the `HermesDB` handle as the remote snapshot
    /// lands or disappears. We must (re)open after every successful refresh:
    /// `sftp` overwrites `state.db` in place, and a SQLite handle held across
    /// that write would read torn pages or `database disk image is malformed`.
    /// We don't recycle the handle on every state change though — invalidate
    /// emits `.stale` without changing file contents, so the open handle is
    /// still good there. The distinguishing signal is a transition out of
    /// `.refreshing`.
    private func observeSnapshot(_ harness: ServerWindowHarness) async {
        guard let snapshot = harness.snapshot else { return }
        var previous: SnapshotState?
        for await state in await snapshot.subscribe() {
            switch state {
            case .fresh, .stale:
                let justRefetched: Bool
                if case .refreshing = previous {
                    justRefetched = true
                } else {
                    justRefetched = false
                }
                if harness.db == nil || justRefetched {
                    await harness.refreshDB()
                }
            case .missing, .refreshing, .error:
                break
            }
            previous = state
        }
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        Group {
            if Idiom.isPhone {
                // Explicit push stack: the collapsed NavigationSplitView's
                // programmatic detail push proved unreliable, so on iPhone we
                // drive a NavigationStack directly from the selection.
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
                    // Back-swipe empties the path — clear the selection so
                    // re-tapping the same session re-pushes the chat.
                    if path.isEmpty, harness.store.selection != nil {
                        harness.store.selection = nil
                    }
                }
            } else {
                NavigationSplitView {
                    sidebar(harness: harness)
                } detail: {
                    detail(harness: harness)
                }
            }
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

    /// iPhone push destination for a selected session.
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
            SessionsSidebar(store: harness.store, snapshot: harness.snapshot)
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

            if !Idiom.isPhone {
                Section("Browse") {
                    browseRow("Sessions", systemImage: "clock.arrow.circlepath", destination: .sessions, store: harness.store)
                    browseRow("Skills", systemImage: "sparkles", destination: .skills, store: harness.store)
                    browseRow("Tools", systemImage: "wrench.and.screwdriver", destination: .tools, store: harness.store)
                    browseRow("Cron", systemImage: "calendar", destination: .cron, store: harness.store)
                    browseRow("Logs", systemImage: "doc.text", destination: .logs, store: harness.store)
                    browseRow("Doctor", systemImage: "stethoscope", destination: .doctor, store: harness.store)
                    browseRow("Updates", systemImage: "arrow.down.circle", destination: .updates, store: harness.store)
                }
            }
        }
        #if os(iOS)
        .toolbar {
            if Idiom.isPhone {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
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
        }
        #endif
        .sheet(isPresented: $showingLogs) {
            LogConsoleView(onDismiss: { showingLogs = false })
        }
        // Settings sheet is attached at the ServerWindow body level so the
        // no-server empty state can present it too.
        .sheet(isPresented: $showingAllSessions) {
            #if os(iOS)
            NavigationStack {
                SessionsBrowser(
                    store: harness.store,
                    db: harness.db,
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
            #endif
        }
    }

    @ViewBuilder
    private func detail(harness: ServerWindowHarness) -> some View {
        if let selection = harness.store.selection,
           let session = harness.store.openSessions.first(where: { $0.id == selection }),
           let viewModel = harness.store.viewModel(for: session.id) {
            ChatView(viewModel: viewModel)
                .id(session.id)
        } else if Idiom.isPhone {
            ContentUnavailableView("Pick a session", systemImage: "bubble.left.and.bubble.right")
        } else {
            switch browse ?? .sessions {
            case .sessions:
                SessionsBrowser(store: harness.store, db: harness.db)
            case .skills: SkillsView(runner: harness.store.adminRunner)
            case .tools: ToolsView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
            case .cron: CronView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
            case .logs:
                LogsView(
                    runner: harness.store.adminRunner,
                    profile: harness.profile,
                    provider: { [weak harness] in
                        // Lambda captures the window-scoped harness so the
                        // LogsHarness it returns outlives any single view
                        // instance. Built lazily — the first sidebar click on
                        // Logs spawns the tailer; subsequent clicks reuse it.
                        guard let harness else { return nil }
                        return harness.ensureLogsHarness(factory: {
                            LogsView.makeTailing(profile: harness.profile)
                        })
                    }
                )
            case .doctor: DoctorView(runner: harness.store.adminRunner, profile: harness.profile)
            case .updates: UpdatesView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
            }
        }
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

/// Bundles the per-window state so we can rebuild it cleanly when the
/// window swaps profiles. SessionsStore and HermesDB hold long-lived
/// resources (live ACP transport, SQLite handle) — making a fresh harness
/// guarantees the previous profile's ones tear down before the new one boots.
///
/// `db` is `@Observable` and mutates: for remote profiles it starts nil and
/// flips to a real `HermesDB` once the snapshot file lands on disk. Without
/// this the first remote window opens against a missing SQLite file and the
/// browser surfaces a raw open error.
@MainActor
@Observable
final class ServerWindowHarness {
    let store: SessionsStore
    let snapshot: RemoteSnapshot?
    let profile: ServerProfile
    /// Drives the trust-on-first-use prompt for unknown SSH host keys. Always
    /// present for SSH profiles; nil for the bundled local profile.
    let hostKeyCoordinator: HostKeyConfirmationCoordinator?
    private(set) var db: HermesDB?
    /// Persistent log tailer. Lives at the window level so the Logs view's
    /// buffered lines survive sidebar tab switches — when the user navigates
    /// away from Logs and back, SwiftUI tears down LogsView and recreates it,
    /// but the underlying ring buffer here continues to accumulate lines.
    /// Lazily created on first access; nil for windows where the profile
    /// doesn't expose a resolvable HERMES_HOME.
    private(set) var logsHarness: LogsHarness?

    private init(
        store: SessionsStore,
        db: HermesDB?,
        snapshot: RemoteSnapshot?,
        profile: ServerProfile,
        hostKeyCoordinator: HostKeyConfirmationCoordinator? = nil
    ) {
        self.store = store
        self.db = db
        self.snapshot = snapshot
        self.profile = profile
        self.hostKeyCoordinator = hostKeyCoordinator
    }

    /// Returns the cached log tailer, or builds one when `factory` produces a
    /// usable tailing implementation. LogsView calls this on appear; the
    /// returned harness keeps streaming even after LogsView is dismissed.
    func ensureLogsHarness(factory: () -> HermesLogTailing?) -> LogsHarness? {
        if let logsHarness { return logsHarness }
        guard let tailing = factory() else { return nil }
        let harness = LogsHarness(tailing: tailing)
        harness.start()
        logsHarness = harness
        return harness
    }

    /// Cancels long-lived per-window resources when the SwiftUI window
    /// disappears. Currently this is just the log tailer — for SSH profiles
    /// it spawns a real `ssh tail -F` subprocess, which would otherwise
    /// outlive its window if the remote logs are quiet. ServerWindow calls
    /// this from `.onDisappear`; the explicit hook is preferred over a
    /// `deinit` because Swift 6 makes MainActor deinits nonisolated, which
    /// would force us to thread the cleanup through a detached Task with
    /// no guarantee about ordering relative to window close.
    func tearDown() {
        logsHarness?.stop()
        logsHarness = nil
    }

    /// Builds a harness backed by an in-process ``MockACPTransport`` for UI
    /// tests — no SSH, no admin runner, no snapshot.
    static func makeMock() -> ServerWindowHarness {
        let manager = SessionManager { MockACPTransport() }
        let store = SessionsStore(manager: manager, adminRunner: nil)
        let profile = ServerProfile(name: "Mock Server", kind: .ssh, host: "mock.local")
        return ServerWindowHarness(store: store, db: nil, snapshot: nil, profile: profile)
    }

    static func make(profile: ServerProfile) -> ServerWindowHarness {
        switch profile.kind {
        case .local:
            #if os(macOS)
            return makeLocal(profile: profile)
            #else
            // Per the iOS transport plan, decision #3: iOS is remote-only.
            // Surface a typed error from the factory so the chat surface
            // can render an actionable empty state instead of crashing.
            let manager = SessionManager { throw TransportError.unsupportedPlatform }
            return ServerWindowHarness(
                store: SessionsStore(manager: manager, adminRunner: nil),
                db: nil,
                snapshot: nil,
                profile: profile
            )
            #endif
        case .ssh:
            return makeRemote(profile: profile)
        }
    }

    /// Re-checks the snapshot path and (re)opens `HermesDB` against the
    /// current file on disk. Called from `ServerWindow` whenever the snapshot
    /// transitions out of `.refreshing` so we never keep an open handle
    /// across the sftp in-place overwrite.
    func refreshDB() async {
        let previous = db
        let config: HermesDBConfiguration
        if let snapshot {
            config = HermesDBConfiguration.forProfile(profile, remoteSnapshotPath: snapshot.localPath())
        } else {
            config = HermesDBConfiguration.forProfile(profile)
        }
        if FileManager.default.fileExists(atPath: config.databaseURL.path) {
            db = HermesDB(configuration: config)
        } else {
            db = nil
        }
        // Close the previous handle after publishing the new one so observers
        // never see a nil gap. The actor's queue serializes pending queries
        // before close() takes effect.
        if let previous {
            await previous.close()
        }
    }

    #if os(macOS)
    private static func makeLocal(profile: ServerProfile) -> ServerWindowHarness {
        let resolver = LoginShellPATHResolver.shared
        resolver.warm()
        let hermesPath = profile.hermesPath
        let hermesHome = profile.hermesHome
        let manager = SessionManager {
            let extraEnv = await resolver.extraEnv()
            var environment = extraEnv
            if let hermesHome {
                environment["HERMES_HOME"] = hermesHome
            }
            let transport = LocalProcessTransport(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [hermesPath, "acp"],
                environment: environment
            )
            try transport.start()
            return transport
        }
        // Mirror the session transport's binary + env so admin commands launch
        // the same hermes the chat session does. Without `profile.hermesPath`
        // here, admin always ran `env hermes …` — which works for chat (chat
        // uses the profile path) but breaks admin when the profile points at
        // an absolute path or a binary name PATH lookup can't find.
        // `COLUMNS=400` keeps hermes' Rich tables from truncating skill names
        // (and other cells) to ellipsis-suffixed strings the parser can't map
        // back to enable/disable commands. Hermes inherits stdout's tty
        // semantics from the parent; without a wide hint, Rich falls back to
        // its 80-col default whenever stdout is a pipe.
        var adminBaseEnv: [String: String] = ["COLUMNS": "400"]
        if let hermesHome {
            adminBaseEnv["HERMES_HOME"] = hermesHome
        }
        let adminRunner = PathAwareHermesAdminRunner(
            inner: LocalHermesAdminRunner(hermesPath: hermesPath, environment: adminBaseEnv),
            resolver: resolver
        )
        let store = SessionsStore(manager: manager, adminRunner: adminRunner)
        let config = HermesDBConfiguration.forProfile(profile)
        let db = FileManager.default.fileExists(atPath: config.databaseURL.path)
            ? HermesDB(configuration: config)
            : nil
        return ServerWindowHarness(store: store, db: db, snapshot: nil, profile: profile)
    }

    #endif

    /// `UserDefaults` key honored on macOS to opt the **ACP transport
    /// and the snapshot fetch** into the pure-Swift NIO-SSH path instead
    /// of the default system-ssh subprocess. The snapshot **backup**
    /// (`sqlite3 .backup`) and **remote cleanup** (`rm -f`) steps in
    /// `RemoteSnapshot` still shell out to `/usr/bin/ssh` even when the
    /// flag is on — closing that gap requires the future NIO-`exec`
    /// command runner that lands with the iOS app target. Host-key
    /// trust therefore consults two verifiers when the flag is enabled:
    /// system-ssh's `known_hosts` for backup/cleanup, ``HostKeyStore``
    /// for ACP + fetch. See `docs/security.md`. iOS always uses NIO
    /// regardless of this flag — system-ssh isn't available there.
    /// Flip the default in a later release and delete system-ssh one
    /// release after that.
    static let useNIOSSHTransportDefaultsKey = "HermesKit.useNIOSSHTransport"

    private static func makeRemote(profile: ServerProfile) -> ServerWindowHarness {
        let useNIO = preferNIOSSHTransport()
        let manager: SessionManager
        let snapshotTransfer: RemoteSnapshotTransfer?

        let hostKeyCoordinator = HostKeyConfirmationCoordinator()
        var snapshotCommandRunner: RemoteCommandRunning?
        if useNIO {
            let credentialProvider: SSHCredentialProvider = FileIdentityProvider()
            let hostKeyStore = defaultHostKeyStore()
            let confirmer: HostKeyConfirmer = { host, port, fingerprint in
                await hostKeyCoordinator.confirm(host: host, port: port, fingerprint: fingerprint)
            }
            manager = SessionManager {
                let transport = try NIOSSHTransport(
                    profile: profile,
                    credentialProvider: credentialProvider,
                    hostKeyStore: hostKeyStore,
                    hostKeyConfirmer: confirmer
                )
                try await transport.start()
                return transport
            }
            snapshotTransfer = NIOSSHCatTransfer(
                profile: profile,
                credentialProvider: credentialProvider,
                hostKeyStore: hostKeyStore,
                hostKeyConfirmer: confirmer
            )
            // Drive the remote `sqlite3 .backup` + cleanup over NIO so
            // snapshot/history works without `/usr/bin/ssh` (required on iOS).
            snapshotCommandRunner = NIOSSHCommandRunner(
                profile: profile,
                credentialProvider: credentialProvider,
                hostKeyStore: hostKeyStore,
                hostKeyConfirmer: confirmer
            )
        } else {
            #if os(macOS)
            manager = SessionManager {
                let transport = SSHTransport(
                    host: profile.host ?? "",
                    user: profile.user,
                    port: profile.port,
                    identityFile: profile.identityFile,
                    hermesPath: profile.hermesPath,
                    hermesHome: profile.hermesHome,
                    remoteShellMode: profile.remoteShellMode,
                    remoteShellPrefix: profile.remoteShellPrefix
                )
                try transport.start()
                return transport
            }
            snapshotTransfer = nil // RemoteSnapshot picks SFTPSubprocessTransfer by default
            #else
            // Defensive: iOS never falls into this branch because
            // `preferNIOSSHTransport()` always returns true off-macOS.
            manager = SessionManager { throw TransportError.unsupportedPlatform }
            snapshotTransfer = nil
            #endif
        }

        let admin = remoteAdminRunner(for: profile)
        let snapshot = RemoteSnapshot(profile: profile, transfer: snapshotTransfer, commandRunner: snapshotCommandRunner)
        let snapshotPath = snapshot.localPath()
        let store = SessionsStore(manager: manager, adminRunner: admin, snapshot: snapshot)
        // Open the DB only if the snapshot file already exists from a prior
        // session. Otherwise wait for `refreshDB()` after the first fetch.
        let db: HermesDB?
        if FileManager.default.fileExists(atPath: snapshotPath.path) {
            let config = HermesDBConfiguration.forProfile(profile, remoteSnapshotPath: snapshotPath)
            db = HermesDB(configuration: config)
        } else {
            db = nil
        }
        return ServerWindowHarness(
            store: store,
            db: db,
            snapshot: snapshot,
            profile: profile,
            hostKeyCoordinator: hostKeyCoordinator
        )
    }

    /// True if we should use the NIO transport for this profile. iOS has
    /// no system-ssh, so it's always true off-macOS. macOS keeps system-ssh
    /// as the default until the flag is flipped.
    private static func preferNIOSSHTransport() -> Bool {
        #if os(macOS)
        return UserDefaults.standard.bool(forKey: useNIOSSHTransportDefaultsKey)
        #else
        return true
        #endif
    }

    /// Process-wide singleton. `PinnedHostKeyStore`'s read-modify-write
    /// atomicity is enforced by an `NSLock` *on the instance* — handing
    /// each `ServerWindowHarness` its own instance would re-introduce
    /// the lost-update window when two windows confirm TOFU pins at the
    /// same time, since both writers would hold different locks while
    /// racing the same JSON file. Sharing the instance keeps the lock
    /// effective across windows.
    private static let sharedPinnedHostKeyStore = PinnedHostKeyStore()

    /// Builds the trust store the NIO transport consults during the host
    /// key callback. On macOS we layer the read-only `~/.ssh/known_hosts`
    /// over our own pinned-store so previously trusted hosts connect
    /// silently. On iOS only the pinned store exists.
    private static func defaultHostKeyStore() -> HostKeyStore {
        let pinned = sharedPinnedHostKeyStore
        #if os(macOS)
        return CompositeHostKeyStore(readers: [KnownHostsFileStore(), pinned], writer: pinned)
        #else
        return pinned
        #endif
    }

    private static func remoteAdminRunner(for profile: ServerProfile) -> (any HermesAdminRunning)? {
        #if os(macOS)
        return RemoteHermesAdminRunner(profile: profile)
        #else
        // iOS doesn't ship `RemoteHermesAdminRunner` (it depends on
        // `OneShotProcess`). Returning nil makes the surface views render
        // empty states instead of crashing — the iOS UI work tracks
        // bringing up an admin runner backed by NIO `exec` requests.
        return nil
        #endif
    }
}
