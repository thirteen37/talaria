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

    /// Acquires the dashboard for `profile`, returning the endpoint and the
    /// supervisor that owns it. Callers hold the returned supervisor and pass
    /// it back to ``release(_:)`` rather than re-looking-up by id — the cached
    /// supervisor for an id can be swapped out from under them by a profile
    /// edit, so id-keyed release would target the wrong instance.
    func acquire(profile: ServerProfile) async throws -> (DashboardEndpoint, DashboardSupervisor) {
        let supervisor = ensure(profile: profile)
        let endpoint = try await supervisor.acquire()
        return (endpoint, supervisor)
    }

    func release(_ supervisor: DashboardSupervisor) async {
        await supervisor.release()
        // Evict once fully released so the next acquire rebuilds against the
        // current profile config — but only if this instance is still the
        // cached one (a profile edit may have already replaced it).
        if supervisors[supervisor.profile.id] === supervisor, await supervisor.isFullyReleased {
            supervisors[supervisor.profile.id] = nil
        }
    }

    private func ensure(profile: ServerProfile) -> DashboardSupervisor {
        // Reuse only when the cached supervisor was built from the same profile
        // config. A profile edit keeps the id but changes hermesPath / host /
        // port / dashboardPort, so an id-only match would spawn the dashboard
        // with stale settings (or reuse a process started with them). The
        // displaced supervisor is still held + released by the harness that
        // acquired it, so its process is torn down — no leak.
        if let existing = supervisors[profile.id], existing.profile == profile {
            return existing
        }
        let supervisor = DashboardSupervisor(
            profile: profile,
            launcher: launcher(for: profile),
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

    /// Local profiles need the login-shell PATH injected (a Finder/Dock-launched
    /// app's environment lacks Homebrew dirs), or `/usr/bin/env hermes dashboard`
    /// can't find a non-absolute `hermes` and the spawn exits before reachable.
    /// Mirrors `PathAwareHermesAdminRunner` for the admin path.
    private func launcher(for profile: ServerProfile) -> any DashboardProcessLauncher {
        switch profile.kind {
        case .local:
            return PathAugmentingDashboardLauncher(
                inner: SystemDashboardProcessLauncher(),
                resolver: LoginShellPATHResolver.shared
            )
        case .ssh:
            return SystemDashboardProcessLauncher()
        }
    }
}

/// Wraps a `DashboardProcessLauncher` to merge the resolved login-shell
/// environment (PATH, etc.) under the spec's own environment before launch.
/// The spec's values win, so an explicit `HERMES_HOME` / `profile.env` still
/// takes precedence over the login-shell PATH.
struct PathAugmentingDashboardLauncher: DashboardProcessLauncher {
    let inner: any DashboardProcessLauncher
    let resolver: LoginShellPATHResolver

    func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess {
        var environment = await resolver.extraEnv()
        for (key, value) in spec.environment {
            environment[key] = value
        }
        let augmented = DashboardSpawnSpec(
            executable: spec.executable,
            arguments: spec.arguments,
            environment: environment
        )
        return try await inner.launch(spec: augmented)
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
    @State private var showingSettings = false
    @State private var showingAllSessions = false
    @State private var showingLogs = false
    /// Drives the iPhone chat push stack. Selecting/creating a session pushes
    /// its id; popping (back-swipe) clears the selection. iPad/macOS use the
    /// NavigationSplitView's detail column instead and ignore this.
    @State private var chatPath: [SessionId] = []
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
            } else if Idiom.isPhone {
                noServerConfiguredView
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(harness?.profile.name ?? directory.profile(id: currentProfileId)?.name ?? "Hermes")
        #if os(macOS)
        .navigationSubtitle(subtitle(for: harness?.profile ?? directory.profile(id: currentProfileId)))
        #endif
        .task(id: currentProfileId) {
            await rebuildHarness()
        }
        #if os(iOS)
        // Auto-build only when no server is active yet (the no-server empty
        // state), so saving the first server connects without a relaunch.
        // Rebuilding while a harness is live would construct a fresh store
        // with no open sessions and drop the in-progress chat, so an existing
        // harness is left in place; profile edits apply on next launch.
        .onChange(of: directory.profiles) { _, _ in
            guard harness == nil else { return }
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
        if let p = directory.profile(id: currentProfileId), p.kind != .local {
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
        let previous = harness
        let profile = directory.profile(id: currentProfileId) ?? ProfileDirectory.localProfile
        harness = ServerWindowHarness.make(profile: profile)
        previous?.tearDown()
        #endif
        // Spawn the per-profile dashboard in the background once the previous
        // harness has released its refcount. Surfaces observe
        // `harness.dashboardClient` flipping non-nil when ready (no-op on iOS
        // until dashboard-over-SSH lands). Done after `tearDown()` so the old
        // profile's supervisor is released before the new one acquires.
        harness?.startDashboard()
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
            // (their `client` never flips non-nil) with no hint as to why.
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
                #if os(macOS)
                .background {
                    // ⌘W normally closes the window; when a session tab is
                    // selected we hijack the shortcut to close that tab
                    // instead. Disabled with no selection so the default
                    // `Performs Close` handles the keystroke as usual.
                    Button("Close Session") {
                        if let id = harness.store.selection {
                            Task { await harness.store.closeTab(id) }
                        }
                    }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(harness.store.selection == nil)
                    .hidden()
                }
                #endif
        } else if Idiom.isPhone {
            ContentUnavailableView("Pick a session", systemImage: "bubble.left.and.bubble.right")
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
    /// Drives the trust-on-first-use prompt for unknown SSH host keys. Always
    /// present for SSH profiles; nil for the bundled local profile.
    let hostKeyCoordinator: HostKeyConfirmationCoordinator?
    /// Aggregates cross-cutting issues (update available, doctor failure)
    /// for the bell + notifications detail page. Built once per harness;
    /// cancelled in `tearDown()`.
    let notifications: WindowNotificationCenter
    /// Live `DashboardClient` once the per-profile supervisor's process has
    /// come online. `nil` until acquired (or while a teardown is in flight),
    /// non-nil for the lifetime of the window's interest in the profile.
    /// Surfaces render a "connecting…" state while this is nil; the window
    /// sidebar surfaces `dashboardError` if acquisition failed.
    var dashboardClient: DashboardClient?
    var dashboardError: String?
    private var dashboardTask: Task<Void, Never>?
    private var dashboardStarted = false
    private var dashboardReleased = false
    #if os(macOS)
    /// The supervisor this harness acquired from `DashboardCoordinator`. Held
    /// so `tearDown()` releases the exact instance it acquired — a profile edit
    /// can swap the coordinator's cached supervisor for the id, so releasing by
    /// id could hit the wrong one.
    private var macDashboardSupervisor: DashboardSupervisor?
    #else
    /// iOS owns its dashboard supervisor directly (one window per profile, no
    /// cross-window refcount sharing as on macOS). Built lazily in
    /// `acquireDashboard()`; released in `tearDown()`.
    private var iosDashboardSupervisor: DashboardSupervisor?
    #endif

    private init(
        store: SessionsStore,
        profile: ServerProfile,
        hostKeyCoordinator: HostKeyConfirmationCoordinator? = nil
    ) {
        self.store = store
        self.profile = profile
        self.hostKeyCoordinator = hostKeyCoordinator
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
            // Chain release behind the acquire task. Cancelling it doesn't stop
            // the supervisor's in-flight spawn (that inner Task doesn't inherit
            // cancellation), so if teardown beats the acquire task to
            // `DashboardCoordinator.acquire`, an independent release would find
            // no registered supervisor, no-op, and leak the spawned process.
            // Awaiting the acquire task first guarantees the supervisor is
            // registered (refcount 1) before we drop our refcount.
            let acquireTask = dashboardTask
            acquireTask?.cancel()
            dashboardTask = nil
            dashboardClient = nil
            store.dashboardClient = nil
            // Await the acquire task first so `macDashboardSupervisor` is set
            // (acquire stores it before returning), then release that exact
            // instance. Strong `self` keeps the harness alive for the brief
            // release so the refcount actually drops.
            Task {
                await acquireTask?.value
                if let supervisor = self.macDashboardSupervisor {
                    await DashboardCoordinator.shared.release(supervisor)
                }
            }
        }
        #else
        if dashboardStarted, !dashboardReleased {
            dashboardReleased = true
            // Same chained-release reasoning as macOS, but the supervisor lives
            // on the harness rather than a shared coordinator. Await the acquire
            // task first so the supervisor has finished spawning (refcount 1)
            // before we release and tear down the SSH connection.
            let acquireTask = dashboardTask
            acquireTask?.cancel()
            dashboardTask = nil
            dashboardClient = nil
            store.dashboardClient = nil
            // Read `iosDashboardSupervisor` *after* the acquire task finishes —
            // the acquire body assigns it before spawning, so capturing it
            // synchronously here (teardown runs before that body) would miss it
            // and leak the SSH connection + remote process. Mirrors the macOS
            // branch above.
            Task {
                await acquireTask?.value
                await self.iosDashboardSupervisor?.release()
                self.iosDashboardSupervisor = nil
            }
        }
        #endif
        notifications.stop()
    }

    func startDashboard() {
        guard !dashboardStarted else { return }
        #if os(macOS)
        dashboardStarted = true
        dashboardTask = Task { [weak self] in
            await self?.acquireDashboard()
        }
        #else
        // iOS reaches the dashboard over NIO-SSH, so it requires a remote
        // server. Local profiles can't run hermes on-device.
        guard profile.kind == .ssh else {
            dashboardError = "Dashboard mode requires a remote (SSH) server."
            return
        }
        dashboardStarted = true
        dashboardTask = Task { [weak self] in
            await self?.acquireDashboard()
        }
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
            let (endpoint, supervisor) = try await DashboardCoordinator.shared.acquire(profile: profile)
            // Store before the cancellation check so `tearDown()` can release
            // the acquired refcount even if we bail out right after.
            macDashboardSupervisor = supervisor
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
        let supervisor = makeIOSDashboardSupervisor()
        iosDashboardSupervisor = supervisor
        do {
            let endpoint = try await supervisor.acquire()
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
        #endif
    }

    #if !os(macOS)
    /// Builds the iOS dashboard supervisor: a NIO-SSH connection that both
    /// execs `hermes dashboard` on the remote host and tunnels its HTTP over a
    /// `direct-tcpip` channel. Reuses the window's host-key trust coordinator
    /// and the shared pinned host-key store so the dashboard connection
    /// doesn't re-prompt for a key the chat transport already trusted.
    private func makeIOSDashboardSupervisor() -> DashboardSupervisor {
        var confirmer: HostKeyConfirmer?
        if let coordinator = hostKeyCoordinator {
            confirmer = { host, port, fingerprint in
                await coordinator.confirm(host: host, port: port, fingerprint: fingerprint)
            }
        }
        let connection = NIOSSHDashboardConnection(
            profile: profile,
            credentialProvider: FileIdentityProvider(),
            hostKeyStore: Self.defaultHostKeyStore(),
            hostKeyConfirmer: confirmer
        )
        let profile = profile
        return DashboardSupervisor(
            profile: profile,
            launcher: NIOSSHDashboardProcessLauncher(connection: connection),
            http: NIOSSHDashboardHTTP(connection: connection),
            portAllocator: {
                // No local forward on iOS, so this is purely the remote bind
                // port. Honor an explicit profile port; otherwise pick a high
                // ephemeral port (collisions surface as the supervisor's
                // not-reachable error).
                if let port = profile.dashboardPort { return port }
                return Int.random(in: 40000...60000)
            }
        )
    }
    #endif

    /// Builds a harness backed by an in-process ``MockACPTransport`` for UI
    /// tests — no SSH, no admin runner, no snapshot.
    static func makeMock() -> ServerWindowHarness {
        let manager = SessionManager { MockACPTransport() }
        let store = SessionsStore(manager: manager, adminRunner: nil)
        let profile = ServerProfile(name: "Mock Server", kind: .ssh, host: "mock.local")
        return ServerWindowHarness(store: store, profile: profile)
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

        let hostKeyCoordinator = HostKeyConfirmationCoordinator()
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
        let store = SessionsStore(
            manager: manager,
            adminRunner: admin,
            // Pause the open timeout while the trust prompt is up so a slow
            // fingerprint comparison doesn't tear down the pending connection.
            isAwaitingUserInput: { hostKeyCoordinator.pending != nil }
        )
        return ServerWindowHarness(
            store: store,
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
