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
        .navigationTitle(directory.profile(id: profileId)?.name ?? "Hermes")
        .task(id: profileId) {
            await directory.reload()
            let profile = directory.profile(id: profileId) ?? ProfileDirectory.localProfile
            harness = ServerWindowHarness.make(profile: profile)
        }
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
            case .tools: ToolsView(runner: harness.store.adminRunner)
            case .cron: CronView(runner: harness.store.adminRunner)
            case .logs: LogsView(runner: harness.store.adminRunner, profile: harness.profile)
            case .doctor: DoctorView(runner: harness.store.adminRunner, profile: harness.profile)
            case .updates: UpdatesView(runner: harness.store.adminRunner)
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
    private(set) var db: HermesDB?

    private init(store: SessionsStore, db: HermesDB?, snapshot: RemoteSnapshot?, profile: ServerProfile) {
        self.store = store
        self.db = db
        self.snapshot = snapshot
        self.profile = profile
    }

    static func make(profile: ServerProfile) -> ServerWindowHarness {
        #if os(macOS)
        switch profile.kind {
        case .local:
            return makeLocal(profile: profile)
        case .ssh:
            return makeRemote(profile: profile)
        }
        #else
        let manager = SessionManager { throw TransportError.unsupportedPlatform }
        return ServerWindowHarness(
            store: SessionsStore(manager: manager, adminRunner: nil),
            db: nil,
            snapshot: nil,
            profile: profile
        )
        #endif
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
        let adminRunner = PathAwareHermesAdminRunner(
            inner: LocalHermesAdminRunner(),
            resolver: resolver
        )
        let store = SessionsStore(manager: manager, adminRunner: adminRunner)
        let config = HermesDBConfiguration.forProfile(profile)
        let db = FileManager.default.fileExists(atPath: config.databaseURL.path)
            ? HermesDB(configuration: config)
            : nil
        return ServerWindowHarness(store: store, db: db, snapshot: nil, profile: profile)
    }

    private static func makeRemote(profile: ServerProfile) -> ServerWindowHarness {
        let manager = SessionManager {
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
        let admin = RemoteHermesAdminRunner(profile: profile)
        let snapshot = RemoteSnapshot(profile: profile)
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
    #endif
}
