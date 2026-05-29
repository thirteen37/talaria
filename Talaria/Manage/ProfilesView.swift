import HermesKit
import SwiftUI

@MainActor
@Observable
final class ProfilesConfigHarness {
    var profiles: [HermesProfileInfo] = []
    /// Reference profile. Defaults to `default` (`~/.hermes`), per the spec.
    var sourceName: String = HermesProfiles.defaultProfileName
    var destName: String = ""
    var comparison: ConfigComparison?
    var lastError: String?
    var isLoading: Bool = false
    var showDifferencesOnly: Bool = false
    /// Set once any call surfaces `commandUnavailable`, so the view banners
    /// instead of looking permanently broken on an older Hermes.
    var profilesUnavailable: Bool = false

    let runner: HermesAdminRunning?
    let profile: ServerProfile

    init(runner: HermesAdminRunning?, profile: ServerProfile) {
        self.runner = runner
        self.profile = profile
    }

    func loadProfiles() async {
        guard let runner else { profiles = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await HermesProfiles.list(runner: runner)
            profiles = list
            profilesUnavailable = false
            lastError = nil
            // Keep source valid; default the destination to the first profile
            // that isn't the source.
            if !list.contains(where: { $0.name == sourceName }) {
                sourceName = list.first?.name ?? HermesProfiles.defaultProfileName
            }
            if destName.isEmpty || !list.contains(where: { $0.name == destName }) {
                destName = list.first(where: { $0.name != sourceName })?.name ?? ""
            }
            await compare()
        } catch {
            handle(error)
        }
    }

    func compare() async {
        // Capture the selection at entry. Picker changes spawn overlapping
        // compare() calls; with variable SSH latency an earlier call can
        // resolve after a later one, so we discard any result whose pair no
        // longer matches the current selection rather than clobbering the
        // newer comparison with stale data.
        let pair = (source: sourceName, dest: destName)
        guard !pair.source.isEmpty, !pair.dest.isEmpty else {
            comparison = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let transfer = makeTransfer()
            async let sourceTextTask = HermesConfigReader.read(profile: profile, profileName: pair.source, transfer: transfer)
            async let destTextTask = HermesConfigReader.read(profile: profile, profileName: pair.dest, transfer: transfer)
            let sourceText = try await sourceTextTask
            let destText = try await destTextTask
            guard sourceName == pair.source, destName == pair.dest else { return }
            let source = try HermesConfigDocument.parse(sourceText)
            let dest = try HermesConfigDocument.parse(destText)
            comparison = ConfigComparison(source: source, dest: dest)
            lastError = nil
        } catch {
            guard sourceName == pair.source, destName == pair.dest else { return }
            comparison = nil
            handle(error)
        }
    }

    /// Builds the SSH transfer for remote reads. `nil` for local profiles (the
    /// reader reads the filesystem directly). macOS-only: iPadOS later injects
    /// a NIO transfer here.
    private func makeTransfer() -> RemoteSnapshotTransfer? {
        guard profile.kind == .ssh else { return nil }
        #if os(macOS)
        return SFTPSubprocessTransfer(profile: profile)
        #else
        return nil
        #endif
    }

    private func handle(_ error: Error) {
        if let profilesError = error as? HermesProfilesError, case .commandUnavailable = profilesError {
            profilesUnavailable = true
            lastError = nil
            profiles = []
            comparison = nil
            return
        }
        lastError = error.localizedDescription
    }
}

struct ProfilesView: View {
    let runner: HermesAdminRunning?
    let profile: ServerProfile

    @State private var harness: ProfilesConfigHarness?

    init(runner: HermesAdminRunning?, profile: ServerProfile) {
        self.runner = runner
        self.profile = profile
    }

    var body: some View {
        Group {
            if runner == nil {
                ContentUnavailableView(
                    "Admin runner unavailable",
                    systemImage: "person.2",
                    description: Text("Open a profile with a Hermes binary to compare profile configs.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Profiles")
        .task {
            if runner == nil { harness = nil; return }
            if harness != nil { return }
            let h = ProfilesConfigHarness(runner: runner, profile: profile)
            harness = h
            await h.loadProfiles()
        }
    }

    @ViewBuilder
    private func content(harness: ProfilesConfigHarness) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let comparison = harness.comparison {
                    let sections = comparison.sections.filter {
                        !(harness.showDifferencesOnly && !$0.hasDifferences)
                    }
                    if sections.isEmpty {
                        ContentUnavailableView(
                            "No differences",
                            systemImage: "checkmark.circle",
                            description: Text("These profiles' configs match.")
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(sections) { section in
                            sectionView(section, harness: harness)
                        }
                    }
                } else if !harness.isLoading {
                    ContentUnavailableView(
                        "Nothing to compare",
                        systemImage: "rectangle.on.rectangle",
                        description: Text("Pick a source and destination profile to compare.")
                    )
                    .padding(.top, 40)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar { toolbar(harness: harness) }
        .manageBanner(bannerMessage(harness: harness), severity: bannerSeverity(harness: harness))
    }

    @ViewBuilder
    private func sectionView(_ section: SectionComparison, harness: ProfilesConfigHarness) -> some View {
        let rows = harness.showDifferencesOnly ? section.rows.filter { $0.status != .same } : section.rows
        DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    ConfigDiffRow(row: row, sourceName: harness.sourceName, destName: harness.destName)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(section.name).font(.headline)
                if section.hasDifferences {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                Spacer()
                // Deferred-copy seam: copy the whole section's source values to
                // the destination profile.
                // TODO: for each changed/source-only row →
                //   hermes -p <destName> config set <keyPath> <sourceValue>
                Button {
                } label: {
                    Label("Copy section →", systemImage: "arrow.right.doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(true)
                .help("Coming soon")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: ProfilesConfigHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Picker("Source", selection: Binding(
                get: { harness.sourceName },
                set: { harness.sourceName = $0; Task { await harness.compare() } }
            )) {
                ForEach(harness.profiles) { Text($0.name).tag($0.name) }
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("Destination", selection: Binding(
                get: { harness.destName },
                set: { harness.destName = $0; Task { await harness.compare() } }
            )) {
                ForEach(harness.profiles) { Text($0.name).tag($0.name) }
            }
            Toggle("Differences only", isOn: Binding(
                get: { harness.showDifferencesOnly },
                set: { harness.showDifferencesOnly = $0 }
            ))
            Button { Task { await harness.loadProfiles() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
        }
    }

    private func bannerMessage(harness: ProfilesConfigHarness) -> String? {
        if let error = harness.lastError { return error }
        if harness.profilesUnavailable { return "Profile listing is unavailable in this Hermes version." }
        return nil
    }

    private func bannerSeverity(harness: ProfilesConfigHarness) -> ManageBanner.Severity {
        harness.lastError != nil ? .error : .warning
    }
}

/// Side-by-side comparison row for one config key-path, adapting `DiffView`'s
/// two-column monospaced card. Tinted by status: changed → amber,
/// only-in-source → red, only-in-destination → green.
struct ConfigDiffRow: View {
    let row: ConfigRowComparison
    let sourceName: String
    let destName: String

    private var background: Color {
        switch row.status {
        case .same: return .gray.opacity(0.08)
        case .changed: return .orange.opacity(0.12)
        case .onlyInSource: return .red.opacity(0.12)
        case .onlyInDest: return .green.opacity(0.12)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.keyPath)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Deferred-copy seam: copy this row's source value to the
                // destination profile.
                // TODO: hermes -p <destName> config set <row.keyPath> <row.sourceValue>
                Button {
                } label: {
                    Label("Copy →", systemImage: "arrow.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(true)
                .help("Coming soon")
            }
            HStack(alignment: .top, spacing: 0) {
                column(title: "Source (\(sourceName))", value: row.sourceValue)
                Divider()
                column(title: "Destination (\(destName))", value: row.destValue)
            }
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func column(title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
