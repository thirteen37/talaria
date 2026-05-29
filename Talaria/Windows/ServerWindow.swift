import HermesKit
import SwiftUI

#if os(macOS)
/// Per-profile dashboard lifecycle for the Talaria app. Owns one
/// `DashboardSupervisor` per profile, reference-counted so multiple windows
/// scoped to the same profile share a single `hermes dashboard` process.
/// Inlined here (rather than its own file) to avoid pbxproj surgery; promote
/// to a standalone Talaria/Dashboard/ group when more dashboard coordination
/// code lands.
@MainActor
final class DashboardCoordinator {
    static let shared = DashboardCoordinator()

    private var supervisors: [UUID: DashboardSupervisor] = [:]
    private let http: any DashboardHTTP = URLSession.shared
    private let launcher: any DashboardProcessLauncher = SystemDashboardProcessLauncher()

    func acquire(profile: ServerProfile) async throws -> DashboardEndpoint {
        let supervisor = ensure(profile: profile)
        return try await supervisor.acquire()
    }

    func release(profile: ServerProfile) async {
        guard let supervisor = supervisors[profile.id] else { return }
        await supervisor.release()
    }

    private func ensure(profile: ServerProfile) -> DashboardSupervisor {
        if let existing = supervisors[profile.id] { return existing }
        let supervisor = DashboardSupervisor(
            profile: profile,
            launcher: launcher,
            http: http,
            portAllocator: {
                if let port = profile.dashboardPort {
                    return port
                }
                return try DashboardPortAllocator.allocate()
            }
        )
        supervisors[profile.id] = supervisor
        return supervisor
    }
}
#endif

// MARK: - Notifications

/// Aggregates cross-cutting per-window issues that warrant attention.
/// Owned by ``ServerWindowHarness``; polls in the background until
/// ``stop()`` is called from `tearDown()`. The bell view in the sidebar
/// observes ``issues`` and lights up when any are present.
@MainActor
@Observable
final class WindowNotificationCenter {
    struct Issue: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case doctorFailure
        }
        let id: Kind
        let title: String
        let detail: String?
        /// Sidebar destination the row's action button navigates to.
        let destination: BrowseDestination
    }

    private(set) var issues: [Issue] = []

    private let adminRunner: HermesAdminRunning?
    private var doctorTask: Task<Void, Never>?

    /// Cadence for admin polls. 30 minutes balances freshness against
    /// shell-out cost on remote profiles.
    private static let adminPollInterval: Duration = .seconds(30 * 60)

    init(adminRunner: HermesAdminRunning?) {
        self.adminRunner = adminRunner
    }

    func start() {
        startDoctorTask()
    }

    func stop() {
        doctorTask?.cancel(); doctorTask = nil
    }

    /// Re-run the admin polls immediately (e.g. when the user opens the
    /// notifications page and wants a fresh read). Existing polling tasks
    /// keep running on their cadence.
    func refreshAdminChecks() {
        Task { await pollDoctor() }
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
            // Preserve the last known doctor verdict across transient
            // network or SSH failures.
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

/// Detail page that lists each active issue with a deep-link button to the
/// relevant sidebar destination.
struct NotificationsView: View {
    let center: WindowNotificationCenter
    let onOpenDestination: (BrowseDestination) -> Void

    var body: some View {
        Group {
            if center.issues.isEmpty {
                ContentUnavailableView(
                    "No notifications",
                    systemImage: "bell.slash",
                    description: Text("Cross-cutting issues will appear here.")
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
        case .doctorFailure:
            Button("Open Doctor") { onOpenDestination(.doctor) }
        }
    }

    private func icon(for kind: WindowNotificationCenter.Issue.Kind) -> String {
        switch kind {
        case .doctorFailure: return "stethoscope"
        }
    }

    private func color(for kind: WindowNotificationCenter.Issue.Kind) -> Color {
        switch kind {
        case .doctorFailure: return .orange
        }
    }
}

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
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(directory.profile(id: currentProfileId)?.name ?? "Hermes")
        .navigationSubtitle(subtitle(for: directory.profile(id: currentProfileId)))
        .task(id: currentProfileId) {
            await directory.reload()
            // Tear the previous profile's harness down before swapping. Without
            // this, swapping the window's profile abandons the old
            // `ServerWindowHarness` without releasing its dashboard refcount,
            // leaking the spawned `hermes dashboard` (the coordinator holds the
            // supervisor strongly, so nothing else releases it). `.onDisappear`
            // only fires on window close, never on profile swap.
            harness?.tearDown()
            let profile = directory.profile(id: currentProfileId) ?? ProfileDirectory.localProfile
            let new = ServerWindowHarness.make(profile: profile)
            harness = new
            // Spawn the per-profile dashboard process in the background so
            // the chat surface (which doesn't need the dashboard) renders
            // immediately. Surfaces that do need it observe
            // `harness.dashboardClient` flipping non-nil when ready.
            new.startDashboard()
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
                SessionsBrowser(store: harness.store, client: harness.dashboardClient)
            case .skills: SkillsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .tools: ToolsView(runner: harness.store.adminRunner, hermesVersion: harness.profile.version)
            case .cron: CronView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .logs:
                LogsView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .doctor:
                DoctorView(
                    runner: harness.store.adminRunner,
                    profile: harness.profile,
                    client: harness.dashboardClient,
                    hermesVersion: harness.profile.version
                )
            case .updates: UpdatesView(client: harness.dashboardClient, hermesVersion: harness.profile.version)
            case .notifications:
                NotificationsView(
                    center: harness.notifications,
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
/// window swaps profiles. The `SessionsStore` holds the live ACP transport;
/// making a fresh harness guarantees the previous profile's one tears down
/// before the new one boots.
@MainActor
@Observable
final class ServerWindowHarness {
    let store: SessionsStore
    let profile: ServerProfile
    /// Aggregates cross-cutting issues (update available, doctor failure)
    /// for the bell + notifications detail page. Built once per harness;
    /// cancelled in `tearDown()`.
    let notifications: WindowNotificationCenter
    /// Live `DashboardClient` once the per-profile supervisor's process has
    /// come online. `nil` until acquired (or while a teardown is in flight),
    /// non-nil for the lifetime of the window's interest in the profile.
    /// Surfaces are responsible for rendering a "connecting…" state while
    /// this is nil and for showing `dashboardError` if acquisition failed.
    var dashboardClient: DashboardClient?
    var dashboardError: String?
    private var dashboardTask: Task<Void, Never>?
    private var dashboardStarted = false
    private var dashboardReleased = false

    private init(store: SessionsStore, profile: ServerProfile) {
        self.store = store
        self.profile = profile
        self.notifications = WindowNotificationCenter(adminRunner: store.adminRunner)
        self.notifications.start()
    }

    /// Cancels long-lived per-window resources when the SwiftUI window
    /// disappears. Releases this window's refcount on the per-profile
    /// dashboard supervisor — the last release terminates the spawned
    /// `hermes dashboard` process. Explicit hook (rather than `deinit`)
    /// because Swift 6 makes MainActor deinits nonisolated, which would
    /// force the teardown through a detached Task with no ordering
    /// guarantee relative to window close.
    func tearDown() {
        #if os(macOS)
        if dashboardStarted, !dashboardReleased {
            dashboardReleased = true
            dashboardTask?.cancel()
            dashboardTask = nil
            dashboardClient = nil
            store.dashboardClient = nil
            // Drop our refcount on the per-profile dashboard supervisor. The
            // coordinator's release is async; fire-and-forget is fine because
            // the window is going away — nothing depends on the teardown
            // completing before the harness is deallocated.
            let profile = profile
            Task { await DashboardCoordinator.shared.release(profile: profile) }
        }
        #endif
        notifications.stop()
    }

    func startDashboard() {
        #if os(macOS)
        guard !dashboardStarted else { return }
        dashboardStarted = true
        dashboardTask = Task { [weak self] in
            await self?.acquireDashboard()
        }
        #else
        dashboardError = "Dashboard mode requires macOS in this release."
        #endif
    }

    /// Acquires the dashboard endpoint for this profile, publishing the
    /// resulting `DashboardClient` so views can observe it. Spawning the
    /// dashboard process can take a moment (Python boot + uvicorn) so
    /// callers should drive this from `.task` and render a loading state
    /// while `dashboardClient` is nil.
    func acquireDashboard() async {
        #if os(macOS)
        do {
            let endpoint = try await DashboardCoordinator.shared.acquire(profile: profile)
            try Task.checkCancellation()
            guard !dashboardReleased else { return }
            dashboardClient = endpoint.session.client()
            store.dashboardClient = dashboardClient
            dashboardError = nil
        } catch {
            guard !Task.isCancelled, !dashboardReleased else { return }
            dashboardClient = nil
            store.dashboardClient = nil
            dashboardError = error.localizedDescription
        }
        #else
        dashboardError = "Dashboard mode requires macOS in this release."
        #endif
    }

    static func make(profile: ServerProfile) -> ServerWindowHarness {
        switch profile.kind {
        case .local:
            #if os(macOS)
            return makeLocal(profile: profile)
            #else
            let manager = SessionManager { throw TransportError.unsupportedPlatform }
            return ServerWindowHarness(
                store: SessionsStore(manager: manager, adminRunner: nil),
                profile: profile
            )
            #endif
        case .ssh:
            return makeRemote(profile: profile)
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
        return ServerWindowHarness(store: store, profile: profile)
    }

    #endif

    /// `UserDefaults` key honored on macOS to opt the ACP transport into
    /// the pure-Swift NIO-SSH path instead of the default system-ssh
    /// subprocess. Host-key trust consults `HostKeyStore` for the NIO
    /// path; system-ssh defers to `~/.ssh/known_hosts`. See
    /// `docs/security.md`. iOS always uses NIO regardless of this flag —
    /// system-ssh isn't available there. Flip the default in a later
    /// release and delete system-ssh one release after that.
    static let useNIOSSHTransportDefaultsKey = "HermesKit.useNIOSSHTransport"

    private static func makeRemote(profile: ServerProfile) -> ServerWindowHarness {
        let useNIO = preferNIOSSHTransport()
        let manager: SessionManager

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
            #else
            // Defensive: iOS never falls into this branch because
            // `preferNIOSSHTransport()` always returns true off-macOS.
            manager = SessionManager { throw TransportError.unsupportedPlatform }
            #endif
        }

        let admin = remoteAdminRunner(for: profile)
        let store = SessionsStore(manager: manager, adminRunner: admin)
        return ServerWindowHarness(store: store, profile: profile)
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
