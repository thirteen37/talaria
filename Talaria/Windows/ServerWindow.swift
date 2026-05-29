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
            portAllocator: { try DashboardPortAllocator.allocate() }
        )
        supervisors[profile.id] = supervisor
        return supervisor
    }
}
#endif

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

    var body: some View {
        Group {
            if let harness {
                content(harness: harness)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(directory.profile(id: profileId)?.name ?? "Hermes")
        .task(id: profileId) {
            await directory.reload()
            // Tear the previous profile's harness down before swapping. Without
            // this, swapping the window's profile abandons the old
            // `ServerWindowHarness` without releasing its dashboard refcount,
            // leaking the spawned `hermes dashboard` (the coordinator holds the
            // supervisor strongly, so nothing else releases it). `.onDisappear`
            // only fires on window close, never on profile swap.
            harness?.tearDown()
            let profile = directory.profile(id: profileId) ?? ProfileDirectory.localProfile
            let new = ServerWindowHarness.make(profile: profile)
            harness = new
            // Spawn the per-profile dashboard process in the background so
            // the chat surface (which doesn't need the dashboard) renders
            // immediately. Surfaces that do need it observe
            // `harness.dashboardClient` flipping non-nil when ready.
            Task { await new.acquireDashboard() }
        }
        .onDisappear {
            // Cancel the window-scoped log tailer (and any future
            // long-lived per-window tasks) when the window closes. Without
            // this an SSH profile leaks its `ssh tail -F` subprocess for
            // every closed window that ever visited the Logs view.
            harness?.tearDown()
        }
    }

    @ViewBuilder
    private func content(harness: ServerWindowHarness) -> some View {
        NavigationSplitView {
            sidebar(harness: harness)
        } detail: {
            detail(harness: harness)
        }
    }

    @ViewBuilder
    private func sidebar(harness: ServerWindowHarness) -> some View {
        List {
            SessionsSidebar(store: harness.store)
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
/// window swaps profiles. The `SessionsStore` holds the live ACP transport;
/// making a fresh harness guarantees the previous profile's one tears down
/// before the new one boots.
@MainActor
@Observable
final class ServerWindowHarness {
    let store: SessionsStore
    let profile: ServerProfile
    /// Live `DashboardClient` once the per-profile supervisor's process has
    /// come online. `nil` until acquired (or while a teardown is in flight),
    /// non-nil for the lifetime of the window's interest in the profile.
    /// Surfaces are responsible for rendering a "connecting…" state while
    /// this is nil and for showing `dashboardError` if acquisition failed.
    var dashboardClient: DashboardClient?
    var dashboardError: String?

    private init(store: SessionsStore, profile: ServerProfile) {
        self.store = store
        self.profile = profile
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
        // Drop our refcount on the per-profile dashboard supervisor. The
        // coordinator's release is async; fire-and-forget is fine because
        // the window is going away — nothing depends on the teardown
        // completing before the harness is deallocated.
        let profile = profile
        Task { await DashboardCoordinator.shared.release(profile: profile) }
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
            dashboardClient = endpoint.session.client()
            store.dashboardClient = dashboardClient
            dashboardError = nil
        } catch {
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
