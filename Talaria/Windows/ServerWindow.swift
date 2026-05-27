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
    case notifications
}

struct ServerWindow: View {
    let profileId: UUID

    @Environment(ProfileDirectory.self) private var directory
    @Environment(RecentServers.self) private var recents
    @State private var harness: ServerWindowHarness?
    @State private var browse: BrowseDestination? = .sessions
    /// Live profile shown in this window. Diverges from `profileId` (the
    /// initial value `WindowGroup` opened with) once the user picks a
    /// different profile from the sidebar switcher; the harness rebuild
    /// keys off this rather than the immutable launch id.
    @State private var activeProfileId: UUID?

    private var currentProfileId: UUID { activeProfileId ?? profileId }

    var body: some View {
        Group {
            if let harness {
                content(harness: harness)
                    .task(id: harness.snapshot?.profile.id) {
                        await observeSnapshot(harness)
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(directory.profile(id: currentProfileId)?.name ?? "Hermes")
        .navigationSubtitle(subtitle(for: directory.profile(id: currentProfileId)))
        .task(id: currentProfileId) {
            await directory.reload()
            let profile = directory.profile(id: currentProfileId) ?? ProfileDirectory.localProfile
            harness = ServerWindowHarness.make(profile: profile)
        }
        .onDisappear {
            // Cancel the window-scoped log tailer (and any future
            // long-lived per-window tasks) when the window closes. Without
            // this an SSH profile leaks its `ssh tail -F` subprocess for
            // every closed window that ever visited the Logs view.
            harness?.tearDown()
        }
    }

    /// In-place profile swap: tears the old harness down before swapping
    /// `activeProfileId`, which then re-fires the `.task` above to build a
    /// fresh harness against the chosen profile.
    private func switchProfile(to newId: UUID) {
        guard newId != currentProfileId else { return }
        recents.record(newId)
        harness?.tearDown()
        harness = nil
        browse = .sessions
        activeProfileId = newId
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
        NavigationSplitView {
            sidebar(harness: harness)
        } detail: {
            detail(harness: harness)
        }
        .background {
            // ⌘W normally closes the window; when a session tab is selected
            // we hijack the shortcut to close that tab instead. With no
            // selection the button is disabled so the default
            // `Performs Close` menu item handles the keystroke as usual.
            Button("Close Session") {
                if let id = harness.store.selection {
                    Task { await harness.store.closeTab(id) }
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(harness.store.selection == nil)
            .hidden()
        }
    }

    @ViewBuilder
    private func sidebar(harness: ServerWindowHarness) -> some View {
        List {
            SessionsSidebar(
                store: harness.store,
                snapshot: harness.snapshot,
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

    @ViewBuilder
    private func detail(harness: ServerWindowHarness) -> some View {
        if let selection = harness.store.selection,
           let session = harness.store.openSessions.first(where: { $0.id == selection }),
           let viewModel = harness.store.viewModel(for: session.id) {
            ChatView(viewModel: viewModel)
                .id(session.id)
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
            case .notifications:
                NotificationsView(
                    center: harness.notifications,
                    snapshot: harness.snapshot,
                    onOpenDestination: { dest in browse = dest }
                )
            }
        }
    }

    /// SSH profiles show `user@host[:port]` in the window title bar so users
    /// can tell two same-named windows apart. Local profiles return an empty
    /// string — SwiftUI hides the subtitle slot entirely when it's empty.
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
    /// Aggregates cross-cutting issues (stale snapshot, update available,
    /// doctor failure) for the bell + notifications detail page. Built once
    /// per harness; cancelled in `tearDown()`.
    let notifications: WindowNotificationCenter
    private(set) var db: HermesDB?
    /// Persistent log tailer. Lives at the window level so the Logs view's
    /// buffered lines survive sidebar tab switches — when the user navigates
    /// away from Logs and back, SwiftUI tears down LogsView and recreates it,
    /// but the underlying ring buffer here continues to accumulate lines.
    /// Lazily created on first access; nil for windows where the profile
    /// doesn't expose a resolvable HERMES_HOME.
    private(set) var logsHarness: LogsHarness?

    private init(store: SessionsStore, db: HermesDB?, snapshot: RemoteSnapshot?, profile: ServerProfile) {
        self.store = store
        self.db = db
        self.snapshot = snapshot
        self.profile = profile
        self.notifications = WindowNotificationCenter(
            snapshot: snapshot,
            adminRunner: store.adminRunner,
            store: store
        )
        self.notifications.start()
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
        notifications.stop()
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

        if useNIO {
            let credentialProvider: SSHCredentialProvider = FileIdentityProvider()
            let hostKeyStore = defaultHostKeyStore()
            manager = SessionManager {
                let transport = try NIOSSHTransport(
                    profile: profile,
                    credentialProvider: credentialProvider,
                    hostKeyStore: hostKeyStore
                )
                try await transport.start()
                return transport
            }
            snapshotTransfer = NIOSSHCatTransfer(
                profile: profile,
                credentialProvider: credentialProvider,
                hostKeyStore: hostKeyStore
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
        let snapshot = RemoteSnapshot(profile: profile, transfer: snapshotTransfer)
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
        return ServerWindowHarness(store: store, db: db, snapshot: snapshot, profile: profile)
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

// MARK: - Notifications

/// Aggregates cross-cutting per-window issues that warrant attention:
/// stale or errored remote snapshot, available hermes update, doctor
/// non-zero exit. Owned by ``ServerWindowHarness``; polls in the
/// background until ``stop()`` is called from `tearDown()`. The bell view
/// in the sidebar observes ``issues`` and lights up when any are present.
@MainActor
@Observable
final class WindowNotificationCenter {
    struct Issue: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case staleSnapshot
            case snapshotError
            case updateAvailable
            case doctorFailure
        }
        let id: Kind
        let title: String
        let detail: String?
        /// Sidebar destination the row's action button navigates to. When
        /// nil the row exposes a local action (e.g. snapshot refresh) instead.
        let destination: BrowseDestination?
    }

    private(set) var issues: [Issue] = []
    /// True while a snapshot refresh is in flight. Surfaced in the
    /// notifications detail page so the user knows a fix is already
    /// underway when they tap on a stale-snapshot row.
    private(set) var snapshotRefreshing: Bool = false

    private let snapshot: RemoteSnapshot?
    private let adminRunner: HermesAdminRunning?
    /// Held only to bump `browserRefreshToken` when a snapshot becomes
    /// `.fresh` — this used to live in the sidebar's own subscription which
    /// the bell replaces.
    private weak var store: SessionsStore?

    private var snapshotTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var doctorTask: Task<Void, Never>?

    /// Cadence for admin polls. 30 minutes is a guess balancing freshness
    /// against shell-out cost on remote profiles; revisit if doctor turns
    /// out to be expensive enough to gate behind a snapshot signal.
    private static let adminPollInterval: Duration = .seconds(30 * 60)

    init(snapshot: RemoteSnapshot?, adminRunner: HermesAdminRunning?, store: SessionsStore?) {
        self.snapshot = snapshot
        self.adminRunner = adminRunner
        self.store = store
    }

    func start() {
        startSnapshotTask()
        startUpdateTask()
        startDoctorTask()
    }

    func stop() {
        snapshotTask?.cancel(); snapshotTask = nil
        updateTask?.cancel(); updateTask = nil
        doctorTask?.cancel(); doctorTask = nil
    }

    /// Kick off an out-of-band refresh from the notifications page's
    /// "Refresh snapshot" action. Errors surface through the snapshot
    /// state stream as `.error`, so we don't need to plumb them here.
    func refreshSnapshot() {
        guard let snapshot else { return }
        Task { try? await snapshot.refresh() }
    }

    /// Re-run the admin polls immediately (e.g. when the user opens the
    /// notifications page and wants a fresh read). Existing polling tasks
    /// keep running on their cadence.
    func refreshAdminChecks() {
        Task { await pollUpdates() }
        Task { await pollDoctor() }
    }

    private func startSnapshotTask() {
        guard let snapshot else { return }
        snapshotTask = Task { [weak self] in
            let initial = await snapshot.currentState()
            await MainActor.run { self?.apply(snapshotState: initial) }
            // Kick off a fetch when no snapshot exists yet — without this,
            // a freshly opened remote window with no cache shows an empty
            // browser indefinitely. Used to live in the sidebar's task.
            if case .missing = initial {
                try? await snapshot.refresh()
            }
            for await state in await snapshot.subscribe() {
                if Task.isCancelled { return }
                await MainActor.run { self?.apply(snapshotState: state) }
            }
        }
    }

    private func apply(snapshotState state: SnapshotState) {
        snapshotRefreshing = false
        switch state {
        case .fresh:
            store?.browserRefreshToken &+= 1
            remove(.staleSnapshot)
            remove(.snapshotError)
        case let .stale(age):
            remove(.snapshotError)
            upsert(Issue(
                id: .staleSnapshot,
                title: "Snapshot stale",
                detail: "Last refreshed \(Self.formatAge(age)). Browsing may show outdated state.",
                destination: nil
            ))
        case let .error(message):
            remove(.staleSnapshot)
            upsert(Issue(
                id: .snapshotError,
                title: "Snapshot refresh failed",
                detail: message,
                destination: nil
            ))
        case .refreshing:
            snapshotRefreshing = true
        case .missing:
            remove(.staleSnapshot)
            remove(.snapshotError)
        }
    }

    private func startUpdateTask() {
        guard adminRunner != nil else { return }
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollUpdates()
                try? await Task.sleep(for: Self.adminPollInterval)
            }
        }
    }

    private func pollUpdates() async {
        guard let runner = adminRunner else { return }
        do {
            let status = try await HermesUpdates.check(runner: runner)
            if status.available {
                let detail = subtitle(for: status)
                upsert(Issue(
                    id: .updateAvailable,
                    title: "Hermes update available",
                    detail: detail,
                    destination: .updates
                ))
            } else {
                remove(.updateAvailable)
            }
        } catch {
            // Polling errors are silent — we don't want to spam the bell
            // with transient `hermes update --check` failures (network
            // glitches, command-unavailable on old hermes builds). We
            // also don't *clear* a previously-recorded valid issue here:
            // an SSH drop mid-poll would otherwise flicker the bell off
            // until the next 30-min poll re-adds it.
        }
    }

    private func subtitle(for status: UpdateStatus) -> String? {
        if let current = status.current, let latest = status.latest {
            return "\(formatVersion(current)) → \(formatVersion(latest))"
        }
        return status.detail
    }

    private func formatVersion(_ v: HermesVersion) -> String {
        var s = "\(v.major).\(v.minor).\(v.patch)"
        if let pre = v.prerelease { s += "-\(pre)" }
        return s
    }

    private func startDoctorTask() {
        guard adminRunner != nil else { return }
        doctorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDoctor()
                try? await Task.sleep(for: Self.adminPollInterval)
            }
        }
    }

    private func pollDoctor() async {
        guard let runner = adminRunner else { return }
        do {
            let report = try await HermesDoctor.run(runner: runner)
            if report.exitCode != 0 {
                let firstSection = report.sections.first.map(\.title)
                upsert(Issue(
                    id: .doctorFailure,
                    title: "Doctor reports issues",
                    detail: firstSection.map { "\($0) (exit \(report.exitCode))" }
                        ?? "Exit \(report.exitCode)",
                    destination: .doctor
                ))
            } else {
                remove(.doctorFailure)
            }
        } catch {
            // Same rationale as `pollUpdates`: preserve the last known
            // doctor verdict across transient failures so the bell stays
            // stable when SSH is flaky.
        }
    }

    private func upsert(_ issue: Issue) {
        if let idx = issues.firstIndex(where: { $0.id == issue.id }) {
            if issues[idx] != issue {
                issues[idx] = issue
            }
        } else {
            issues.append(issue)
        }
    }

    private func remove(_ kind: Issue.Kind) {
        issues.removeAll { $0.id == kind }
    }

    static func formatAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

/// Bell shown in the sidebar header. Lights up when the center has any
/// active issues; tapping navigates the window to the notifications page.
struct NotificationBell: View {
    let center: WindowNotificationCenter
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: center.issues.isEmpty ? "bell" : "bell.badge.fill")
                    .foregroundStyle(center.issues.isEmpty ? .secondary : Color.accentColor)
                if !center.issues.isEmpty {
                    Text("\(center.issues.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(center.issues.isEmpty ? "No notifications" : "\(center.issues.count) notification(s)")
    }
}

/// Detail page that lists each active issue with a deep-link button to
/// the relevant sidebar destination (Updates / Doctor) or a local action
/// (refresh snapshot). Mirrors the bell — when the center is empty this
/// page shows a "no issues" placeholder.
struct NotificationsView: View {
    let center: WindowNotificationCenter
    let snapshot: RemoteSnapshot?
    let onOpenDestination: (BrowseDestination) -> Void

    var body: some View {
        Group {
            if center.issues.isEmpty {
                ContentUnavailableView(
                    "No notifications",
                    systemImage: "bell.slash",
                    description: Text(center.snapshotRefreshing
                        ? "A snapshot refresh is in progress."
                        : "Cross-cutting issues will appear here.")
                )
            } else {
                List {
                    ForEach(center.issues) { issue in
                        row(for: issue)
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .task {
            // Out-of-band poll so the page reflects current state instead
            // of waiting up to 30 min for the next scheduled check.
            center.refreshAdminChecks()
        }
    }

    @ViewBuilder
    private func row(for issue: WindowNotificationCenter.Issue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: issue.id))
                .foregroundStyle(color(for: issue.id))
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.headline)
                if let detail = issue.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButton(for: issue)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButton(for issue: WindowNotificationCenter.Issue) -> some View {
        switch issue.id {
        case .staleSnapshot, .snapshotError:
            Button {
                center.refreshSnapshot()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(center.snapshotRefreshing || snapshot == nil)
        case .updateAvailable:
            Button("Open Updates") { onOpenDestination(.updates) }
        case .doctorFailure:
            Button("Open Doctor") { onOpenDestination(.doctor) }
        }
    }

    private func icon(for kind: WindowNotificationCenter.Issue.Kind) -> String {
        switch kind {
        case .staleSnapshot: return "clock.badge.exclamationmark"
        case .snapshotError: return "exclamationmark.triangle.fill"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .doctorFailure: return "stethoscope"
        }
    }

    private func color(for kind: WindowNotificationCenter.Issue.Kind) -> Color {
        switch kind {
        case .staleSnapshot: return .yellow
        case .snapshotError: return .red
        case .updateAvailable: return .accentColor
        case .doctorFailure: return .orange
        }
    }
}
