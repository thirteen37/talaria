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
    @State private var store: SessionsStore = ServerWindow.makeStore()
    @State private var browse: BrowseDestination? = .sessions
    @State private var db: HermesDB? = ServerWindow.makeDB()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Hermes")
    }

    @ViewBuilder
    private var sidebar: some View {
        List {
            SessionsSidebar(store: store)
                .onChange(of: store.selection) { _, newValue in
                    if newValue != nil {
                        browse = nil
                    }
                }

            if let error = store.lastError {
                Section {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            Button("Dismiss") { store.lastError = nil }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                        }
                    }
                }
            }

            Section("Browse") {
                browseRow("Sessions", systemImage: "clock.arrow.circlepath", destination: .sessions)
                browseRow("Skills", systemImage: "sparkles", destination: .skills)
                browseRow("Tools", systemImage: "wrench.and.screwdriver", destination: .tools)
                browseRow("Cron", systemImage: "calendar", destination: .cron)
                browseRow("Logs", systemImage: "doc.text", destination: .logs)
                browseRow("Doctor", systemImage: "stethoscope", destination: .doctor)
                browseRow("Updates", systemImage: "arrow.down.circle", destination: .updates)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection = store.selection,
           let session = store.openSessions.first(where: { $0.id == selection }),
           let viewModel = store.viewModel(for: session.id) {
            ChatView(viewModel: viewModel)
                .id(session.id)
        } else {
            switch browse ?? .sessions {
            case .sessions:
                SessionsBrowser(store: store, db: db)
            case .skills: SkillsView()
            case .tools: ToolsView()
            case .cron: CronView()
            case .logs: LogsView()
            case .doctor: DoctorView()
            case .updates: UpdatesView()
            }
        }
    }

    private func browseRow(_ title: String, systemImage: String, destination: BrowseDestination) -> some View {
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

    private static func makeStore() -> SessionsStore {
        #if os(macOS)
        let resolver = LoginShellPATHResolver.shared
        resolver.warm()
        let manager = SessionManager {
            let extraEnv = await resolver.extraEnv()
            let transport = LocalProcessTransport(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["hermes", "acp"],
                environment: extraEnv
            )
            try transport.start()
            return transport
        }
        let adminRunner = PathAwareHermesAdminRunner(
            inner: LocalHermesAdminRunner(),
            resolver: resolver
        )
        return SessionsStore(manager: manager, adminRunner: adminRunner)
        #else
        let manager = SessionManager { throw TransportError.unsupportedPlatform }
        return SessionsStore(manager: manager, adminRunner: nil)
        #endif
    }

    private static func makeDB() -> HermesDB? {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("state.db", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return HermesDB(configuration: HermesDBConfiguration(databaseURL: url))
    }
}
