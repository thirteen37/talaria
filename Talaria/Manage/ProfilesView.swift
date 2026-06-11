import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// Editor draft for the secondary pane — either cloning an existing profile or
/// renaming one. Both capture a single free-form `newName` field.
struct ProfileDraft: Equatable {
    enum Mode: Equatable {
        /// Clone `source` into a brand-new profile.
        case clone(source: String)
        /// Rename `original` to the entered name.
        case rename(original: String)
    }

    var mode: Mode
    var newName: String = ""
}

@MainActor
@Observable
final class ProfilesHarness {
    var profiles: [HermesProfileInfo] = []
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// the surface id so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    var isLoading: Bool = false
    var selectionID: HermesProfileInfo.ID?
    var draft: ProfileDraft?

    // MARK: - Distribution state

    /// Install-from-source form, shown in the secondary pane when non-nil.
    var installDraft: InstallDraft?
    /// `distribution.yaml` author + publish form, shown in the secondary pane.
    var manifestEditor: ManifestEditorState?
    /// True while the read-only manifest view occupies the secondary pane.
    var viewingManifest = false
    /// The selected profile's parsed manifest (loaded on selection change).
    var selectedInfo: ProfileDistributionInfo?
    var infoLoading = false
    /// Set when `loadInfo` fails (a read error, not the "not a distribution"
    /// sentinel), so the manifest pane shows the failure rather than falsely
    /// claiming the profile has no `distribution.yaml`.
    var infoError: String?
    /// True while a distribution mutation (install/update/export/import/publish)
    /// is in flight, so the toolbar disables re-entry and shows progress.
    var busy = false
    /// A produced `.tar.gz` ready for the `.fileExporter` save panel, or nil.
    var pendingExport: ExportPayload?
    /// Result of an in-pane manifest action (Save / Publish stdout), rendered in
    /// the manifest editor's Result section. Menu/form actions (install / update
    /// / import) confirm via a top-of-window success banner instead, so they
    /// don't use this.
    var lastOutput: String?

    private let client: DashboardClient?
    private let runner: HermesAdminRunning?
    private let profile: ServerProfile
    private let snapshotTransfer: RemoteSnapshotTransfer?
    private let hostShell: HostShellRunning?
    /// Invoked after any successful mutation so the window can refresh its
    /// sidebar switcher and reconcile the active `-p <name>` if it vanished.
    private let onProfilesChanged: () -> Void

    init(
        client: DashboardClient?,
        runner: HermesAdminRunning?,
        profile: ServerProfile,
        snapshotTransfer: RemoteSnapshotTransfer? = nil,
        hostShell: HostShellRunning? = nil,
        onProfilesChanged: @escaping () -> Void
    ) {
        self.client = client
        self.runner = runner
        self.profile = profile
        self.snapshotTransfer = snapshotTransfer
        self.hostShell = hostShell
        self.onProfilesChanged = onProfilesChanged
    }

    /// True when any secondary-pane content is active (clone/rename, install,
    /// manifest view, or the author/publish editor).
    var secondaryActive: Bool {
        draft != nil || installDraft != nil || manifestEditor != nil || viewingManifest
    }

    /// Dismisses every secondary-pane mode.
    func closeSecondary() {
        draft = nil
        installDraft = nil
        manifestEditor = nil
        viewingManifest = false
    }

    var selectedProfile: HermesProfileInfo? {
        guard let id = selectionID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// The dashboard API can only clone from `default`, so cloning is offered
    /// only when the default profile is selected.
    var canClone: Bool {
        guard let profile = selectedProfile else { return false }
        return profile.isDefault || profile.name == HermesProfiles.defaultProfileName
    }

    /// Dashboard-only (clone/rename/delete + list go through `/api/profiles`;
    /// only the distribution commands use the CLI runner). On failure the error
    /// is surfaced rather than degrading to CLI-parsed data. `client == nil` is
    /// handled upstream by the view's "Dashboard not ready" state.
    func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.listProfiles()
            profiles = list.map {
                HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, model: $0.model)
            }
            lastError = nil
            banners?.dismiss(key: "profiles")
        } catch {
            let message = error.localizedDescription
            lastError = message
            banners?.surfaceError("profiles", message)
        }
    }

    // MARK: - Editor lifecycle

    func beginClone(source: String) {
        draft = ProfileDraft(mode: .clone(source: source))
    }

    func beginRename(original: String) {
        draft = ProfileDraft(mode: .rename(original: original), newName: original)
    }

    func cancelEdit() { draft = nil }

    // MARK: - Mutations

    /// Clones into a new profile `rawName`. The dashboard API can only clone
    /// from `default`, so the UI gates Clone to the default row and this always
    /// seeds from default.
    func clone(newName rawName: String) async {
        if let message = validateNewName(rawName) {
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        let name = normalized(rawName)
        let message = await runWrite { try await $0.createProfile(name: name, cloneFromDefault: true, noSkills: false) }
        await finishWrite(message)
    }

    func rename(from original: String, to rawName: String) async {
        guard original != HermesProfiles.defaultProfileName else {
            let message = "The default profile cannot be renamed."
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        if let message = validateNewName(rawName) {
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        let name = normalized(rawName)
        let message = await runWrite { try await $0.renameProfile(name: original, newName: name) }
        await finishWrite(message)
    }

    func delete(name: String) async {
        guard name != HermesProfiles.defaultProfileName else {
            let message = "The default profile cannot be deleted."
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        let message = await runWrite { try await $0.deleteProfile(name: name) }
        await finishWrite(message)
    }

    // MARK: - Distribution lifecycle

    func beginInstall() {
        closeSecondary()
        lastOutput = nil
        installDraft = InstallDraft()
    }

    /// Loads the selected profile's manifest into the read-only view pane.
    func beginViewManifest(name: String) {
        closeSecondary()
        viewingManifest = true
        Task { await loadInfo(name: name) }
    }

    /// Reads the profile's `distribution.yaml` (or starts a blank one) into the
    /// author/publish editor.
    func beginAuthorManifest(name: String) {
        closeSecondary()
        lastOutput = nil
        // Seed a blank editor immediately (name prefilled); the async read
        // upgrades it to the existing manifest if one is on disk.
        manifestEditor = ManifestEditorState(profileName: name, fields: ManifestFields(name: name))
        Task { await loadManifest(name: name) }
    }

    private func loadManifest(name: String) async {
        guard manifestEditor?.profileName == name, let runner else { return }
        // The state `beginAuthorManifest` seeded. The read below makes SSH
        // round-trips on a remote profile, so the editor may already be visible
        // and edited by the time it returns — only adopt the on-disk manifest if
        // the user hasn't touched the seeded form (or switched away).
        let seeded = ManifestEditorState(profileName: name, fields: ManifestFields(name: name))
        do {
            // Named profiles live in ~/.hermes/profiles/<name>/, not the default
            // home, so resolve the profile's actual directory rather than reading
            // `.profileRelative` against the window's (default) hermesHome.
            let dir = try await HermesProfiles.profileDirectory(runner: runner, name: name)
            let text = try await HermesFileStore.read(
                profile: profile,
                location: .resolved(path: manifestPath(in: dir)),
                transfer: snapshotTransfer
            )
            let parsed = try DistributionManifest(parsingYAML: text)
            guard manifestEditor == seeded else { return }
            var editor = ManifestEditorState(profileName: name, fields: ManifestFields(parsed))
            editor.version = parsed.version ?? ""
            manifestEditor = editor
        } catch HermesFileStoreError.notFound {
            // No manifest on disk yet — keep the seeded blank editor.
        } catch {
            surface(error.localizedDescription)
        }
    }

    // MARK: - Distribution actions

    func loadInfo(name: String) async {
        guard let runner else { selectedInfo = nil; return }
        infoLoading = true
        defer { infoLoading = false }
        do {
            let info = try await HermesProfiles.info(runner: runner, name: name)
            // Selection may have changed while info() was in flight (likely on a
            // slow remote profile); don't paint a stale profile's manifest.
            guard selectedProfile?.name == name else { return }
            selectedInfo = info
            infoError = nil
        } catch {
            guard selectedProfile?.name == name else { return }
            // A read failure — distinct from the "not a distribution" sentinel —
            // so the pane shows the error rather than "no distribution.yaml".
            selectedInfo = nil
            infoError = error.localizedDescription
            lastError = error.localizedDescription
            banners?.surfaceError("profiles", error.localizedDescription)
        }
    }

    func installDistribution() async {
        guard let runner, let draft = installDraft else { return }
        let source = draft.source.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else {
            surface("Enter a git URL or local directory to install from.")
            return
        }
        busy = true
        defer { busy = false }
        do {
            _ = try await HermesProfiles.install(
                runner: runner,
                source: source,
                name: draft.name.trimmingCharacters(in: .whitespaces),
                alias: draft.alias,
                force: draft.force
            )
            lastError = nil
            installDraft = nil
            await refresh()
            onProfilesChanged()
            // Menu/form actions have no in-pane result line, so confirm via the
            // top-of-window success banner.
            banners?.surfaceSuccess("profiles", "Installed distribution.")
        } catch {
            surface(error.localizedDescription)
        }
    }

    func update(name: String, forceConfig: Bool) async {
        guard let runner else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await HermesProfiles.update(runner: runner, name: name, forceConfig: forceConfig)
            lastError = nil
            await refresh()
            if viewingManifest { await loadInfo(name: name) }
            banners?.surfaceSuccess("profiles", "Updated “\(name)”.")
        } catch {
            surface(error.localizedDescription)
        }
    }

    /// Exports `name` to a `.tar.gz`, populating ``pendingExport`` for the
    /// `.fileExporter`. Local profiles export straight to a temp file; remote
    /// profiles export to a host temp path, then the archive is fetched back.
    func export(name: String) async {
        guard let runner else { return }
        busy = true
        lastOutput = nil
        defer { busy = false }
        let filename = "\(name).tar.gz"
        do {
            let data: Data
            if profile.kind == .local {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("talaria-export-\(UUID().uuidString).tar.gz")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try await HermesProfiles.export(runner: runner, name: name, outputPath: tmp.path)
                data = try Data(contentsOf: tmp)
            } else {
                guard let transfer = resolvedTransfer() else {
                    throw HermesFileStoreError.transferUnavailable
                }
                let remoteTmp = "/tmp/talaria-export-\(UUID().uuidString).tar.gz"
                try await HermesProfiles.export(runner: runner, name: name, outputPath: remoteTmp)
                let localTmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("talaria-export-\(UUID().uuidString).tar.gz")
                defer { try? FileManager.default.removeItem(at: localTmp) }
                // Clean up the host temp on every path — a failed fetch/read must
                // not leak it in the remote /tmp (defer can't await, so do/catch).
                do {
                    try await transfer.fetch(remotePath: remoteTmp, to: localTmp)
                    data = try Data(contentsOf: localTmp)
                } catch {
                    await removeRemoteTemp(remoteTmp)
                    throw error
                }
                await removeRemoteTemp(remoteTmp)
            }
            lastError = nil
            pendingExport = ExportPayload(document: TarGzDocument(data: data), filename: filename)
        } catch {
            surface(error.localizedDescription)
        }
    }

    /// Imports a distribution from picked archive bytes. Local profiles import
    /// from a temp file; remote profiles upload it to a host temp path first.
    func importArchive(data: Data, name: String?) async {
        guard let runner else { return }
        busy = true
        defer { busy = false }
        do {
            let localTmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("talaria-import-\(UUID().uuidString).tar.gz")
            try data.write(to: localTmp, options: .atomic)
            defer { try? FileManager.default.removeItem(at: localTmp) }

            if profile.kind == .local {
                _ = try await HermesProfiles.importArchive(runner: runner, archivePath: localTmp.path, name: name)
            } else {
                guard let transfer = resolvedTransfer() else {
                    throw HermesFileStoreError.transferUnavailable
                }
                let remoteTmp = "/tmp/talaria-import-\(UUID().uuidString).tar.gz"
                try await transfer.upload(from: localTmp, to: remoteTmp)
                // Clean up the host temp on every path (a failed import must not
                // leak it in the remote /tmp).
                do {
                    _ = try await HermesProfiles.importArchive(runner: runner, archivePath: remoteTmp, name: name)
                } catch {
                    await removeRemoteTemp(remoteTmp)
                    throw error
                }
                await removeRemoteTemp(remoteTmp)
            }
            lastError = nil
            await refresh()
            onProfilesChanged()
            banners?.surfaceSuccess("profiles", "Imported distribution.")
        } catch {
            surface(error.localizedDescription)
        }
    }

    /// Writes the edited manifest to the profile's `distribution.yaml`.
    func saveManifest() async {
        guard let editor = manifestEditor, let runner else { return }
        let manifest = editor.fields.toManifest()
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            surface("The manifest needs a name.")
            return
        }
        busy = true
        lastOutput = nil
        defer { busy = false }
        do {
            let dir = try await HermesProfiles.profileDirectory(runner: runner, name: editor.profileName)
            try await writeManifest(manifest, in: dir)
            lastError = nil
            markSaved()
            lastOutput = "Wrote distribution.yaml for “\(editor.profileName)”."
            if viewingManifest { await loadInfo(name: editor.profileName) }
        } catch {
            surface(error.localizedDescription)
        }
    }

    /// Publishes the profile distribution to git via the host shell. The form's
    /// manifest is **written first** so a Publish without a prior explicit Save
    /// still commits the edits the user sees — and only the distribution
    /// allowlist (+ `distribution_owned`) is staged, never the profile home's
    /// secrets/DB.
    func publish() async {
        guard let runner, let hostShell, let editor = manifestEditor else {
            surface("Publishing requires the Hermes CLI and host access.")
            return
        }
        let manifest = editor.fields.toManifest()
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            surface("The manifest needs a name before publishing.")
            return
        }
        let url = editor.remoteURL.trimmingCharacters(in: .whitespaces)
        let version = editor.version.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !version.isEmpty else {
            surface("Publishing needs a git remote URL and a version/tag.")
            return
        }
        let message = editor.commitMessage.trimmingCharacters(in: .whitespaces)
        busy = true
        lastOutput = nil
        defer { busy = false }
        do {
            // Resolve the profile's actual home first, then persist the in-form
            // manifest THERE before committing — so the published commit reflects
            // unsaved edits and lands in the same directory git runs in (named
            // profiles live in ~/.hermes/profiles/<name>/, not the default home).
            let directory = try await HermesProfiles.profileDirectory(runner: runner, name: editor.profileName)
            try await writeManifest(manifest, in: directory)
            markSaved()
            let output = try await DistributionPublisher.publish(
                shell: hostShell,
                directory: directory,
                remoteURL: url,
                version: version,
                message: message.isEmpty ? "Publish \(version)" : message,
                ownedPaths: manifest.distributionOwned ?? []
            )
            lastError = nil
            lastOutput = output.isEmpty ? "Published \(version)." : output
        } catch {
            surface(error.localizedDescription)
        }
    }

    /// Encodes `manifest` and writes it to `distribution.yaml` in the resolved
    /// profile `directory` (the parent of `hermes -p <name> config path`),
    /// through the same direct-file path the Memory editor uses.
    private func writeManifest(_ manifest: DistributionManifest, in directory: String) async throws {
        let yaml = try manifest.encodeYAML()
        try await HermesFileStore.write(
            yaml,
            profile: profile,
            location: .resolved(path: manifestPath(in: directory)),
            transfer: snapshotTransfer
        )
    }

    /// The `distribution.yaml` path inside a resolved profile home.
    private func manifestPath(in directory: String) -> String {
        (directory as NSString).appendingPathComponent("distribution.yaml")
    }

    /// Marks the active editor as saved, for the secondary pane's state.
    private func markSaved() {
        guard var editor = manifestEditor else { return }
        editor.lastSaved = true
        manifestEditor = editor
    }

    /// Resolves a transfer for binary archive movement: the injected one, else
    /// the macOS system-ssh SFTP fallback. nil when none is possible.
    private func resolvedTransfer() -> RemoteSnapshotTransfer? {
        if let snapshotTransfer { return snapshotTransfer }
        #if os(macOS)
        if profile.kind == .ssh { return SFTPSubprocessTransfer(profile: profile) }
        #endif
        return nil
    }

    /// Best-effort removal of a host temp file used to stage an export/import
    /// archive. Called on both success and failure paths so a failed
    /// fetch/import doesn't leak it in the remote `/tmp`.
    private func removeRemoteTemp(_ path: String) async {
        _ = try? await hostShell?.runShell("rm -f \(ShellQuoting.shellQuote(path))", workingDirectory: nil)
    }

    private func surface(_ message: String) {
        lastError = message
        banners?.surfaceError("profiles", message)
    }

    // MARK: - Plumbing

    /// Runs a profile write against the dashboard. Returns nil on success, the
    /// dashboard error's description on failure (its HTTP 400 `detail` is the
    /// informative message), or a "no dashboard" message when `client == nil`.
    /// Clone/rename/delete are dashboard-only; the distribution commands use the
    /// CLI runner directly.
    private func runWrite(_ dashboard: (DashboardClient) async throws -> Void) async -> String? {
        guard let client else { return "No dashboard available to manage profiles." }
        do { try await dashboard(client); return nil }
        catch { return error.localizedDescription }
    }

    private func finishWrite(_ message: String?) async {
        if let message {
            lastError = message
            banners?.surfaceError("profiles", message)
            return
        }
        lastError = nil
        draft = nil
        await refresh()
        onProfilesChanged()
    }

    /// Lowercased, whitespace-trimmed name as sent to the backend. Hermes
    /// normalizes to lowercase itself, but doing it here keeps the optimistic
    /// validation and the request in agreement.
    private func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Light client-side check; the backend remains the source of truth for
    /// reserved/colliding names. Returns an error message or nil when valid.
    private func validateNewName(_ raw: String) -> String? {
        let name = normalized(raw)
        guard !name.isEmpty else { return "Profile name cannot be empty." }
        guard name != HermesProfiles.defaultProfileName else { return "“default” is a reserved name." }
        guard name.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil else {
            return "Use lowercase letters, digits, “-” or “_”, starting with a letter or digit."
        }
        return nil
    }
}

struct ProfilesView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let profile: ServerProfile
    let snapshotTransfer: RemoteSnapshotTransfer?
    let hostShell: HostShellRunning?
    let activeProfile: String
    let hermesVersion: HermesVersion?
    let onProfilesChanged: () -> Void

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: an `EntityLink` to a Hermes profile selects its row when
    /// this page lands. Optional so the page renders without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: ProfilesHarness?
    @State private var profileToDelete: HermesProfileInfo?
    /// Drives the `.tar.gz` import file picker.
    @State private var showingImporter = false

    init(
        client: DashboardClient?,
        runner: HermesAdminRunning?,
        profile: ServerProfile,
        snapshotTransfer: RemoteSnapshotTransfer? = nil,
        hostShell: HostShellRunning? = nil,
        activeProfile: String = HermesProfiles.defaultProfileName,
        hermesVersion: HermesVersion? = nil,
        onProfilesChanged: @escaping () -> Void = {}
    ) {
        self.client = client
        self.runner = runner
        self.profile = profile
        self.snapshotTransfer = snapshotTransfer
        self.hostShell = hostShell
        self.activeProfile = activeProfile
        self.hermesVersion = hermesVersion
        self.onProfilesChanged = onProfilesChanged
    }

    /// Distribution affordances are enabled only with a CLI runner and a Hermes
    /// new enough for the `profile` distribution subcommands.
    private var distributionsAvailable: Bool {
        runner != nil && CapabilityTable().has(.profileDistributions, in: hermesVersion)
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "square.stack.3d.up",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Profiles")
        .dismissesBanner("profiles", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (matching Cron).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { consumeFocus(harness: harness!); return }
            let h = ProfilesHarness(
                client: client,
                runner: runner,
                profile: profile,
                snapshotTransfer: snapshotTransfer,
                hostShell: hostShell,
                onProfilesChanged: onProfilesChanged
            )
            h.banners = banners
            harness = h
            await h.refresh()
            consumeFocus(harness: h)
        }
        // Re-entering this page (focus set before it appeared) and a profile
        // EntityLink tapped while already on it both select the row.
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
    }

    /// Selects the row named by a pending Hermes-profile focus, then clears it.
    /// Ignores focus aimed at another page.
    private func consumeFocus(harness: ProfilesHarness) {
        guard let ref = navigator?.pendingFocus, case let .hermesProfile(name) = ref else { return }
        if let match = harness.profiles.first(where: { $0.name == name }) {
            harness.selectionID = match.id
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: ProfilesHarness) -> some View {
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.secondaryActive },
                set: { if !$0 { harness.closeSecondary() } }
            ),
            secondaryTitle: editorTitle(harness)
        ) {
            profilesTable(harness: harness)
                .frame(minWidth: Idiom.isPhone ? nil : 360, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            editorPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        // Hard errors route to the top-of-window strip; only the capability warnings stay in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresDashboard,
                feature: "Profile management via Hermes dashboard",
                version: hermesVersion
            )
                ?? capabilityBanner(
                    .profileDistributions,
                    feature: "Installing, updating and publishing profile distributions",
                    version: hermesVersion
                ),
            severity: .warning
        )
        .fileExporter(
            isPresented: Binding(
                get: { harness.pendingExport != nil },
                set: { if !$0 { harness.pendingExport = nil } }
            ),
            document: harness.pendingExport?.document ?? TarGzDocument(data: Data()),
            contentType: .tarGZ,
            defaultFilename: harness.pendingExport?.filename ?? "profile.tar.gz"
        ) { result in
            if case .failure(let error) = result { harness.lastError = error.localizedDescription }
            harness.pendingExport = nil
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.tarGZ, .gzip, .data]
        ) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    Task { await harness.importArchive(data: data, name: nil) }
                } catch {
                    harness.lastError = error.localizedDescription
                }
            case .failure(let error):
                harness.lastError = error.localizedDescription
            }
        }
        // Selecting a profile opens (or refreshes) its manifest view — unless the
        // user is mid-edit in another secondary mode (install / author / clone /
        // rename), which we must not clobber.
        .onChange(of: harness.selectionID) { _, _ in
            guard distributionsAvailable else { return }
            let editing = harness.installDraft != nil
                || harness.manifestEditor != nil
                || harness.draft != nil
            guard !editing else { return }
            if let selected = harness.selectedProfile {
                harness.beginViewManifest(name: selected.name)
            } else if harness.viewingManifest {
                harness.closeSecondary()
            }
        }
        .alert(
            "Delete profile?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            presenting: profileToDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                Task { await harness.delete(name: profile.name) }
            }
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: { profile in
            Text("“\(profile.name)” and its config, memories, and skills will be permanently removed. This cannot be undone.")
        }
    }

    @ViewBuilder
    private func profilesTable(harness: ProfilesHarness) -> some View {
        Table(harness.profiles, selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            TableColumn("Name") { profile in
                HStack(spacing: 6) {
                    Text(profile.name)
                    if profile.name == activeProfile {
                        Text("active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            TableColumn("Default") { profile in
                if profile.isDefault {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                }
            }
            .width(60)
            TableColumn("Model") { profile in
                if let model = profile.model, !model.isEmpty {
                    EntityLink(model, ref: .modelMain, style: .prominent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if harness.profiles.isEmpty, !harness.isLoading {
                ContentUnavailableView("No profiles", systemImage: "square.stack.3d.up")
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: ProfilesHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload the profile list")
            Button {
                guard let profile = harness.selectedProfile else { return }
                harness.beginClone(source: profile.name)
            } label: {
                Label("Clone", systemImage: "plus.square.on.square")
            }
            .disabled(!harness.canClone)
            .help("Create a new profile from default")
            Button {
                guard let profile = harness.selectedProfile else { return }
                harness.beginRename(original: profile.name)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(renameDeleteDisabled(harness))
            .help("Rename the selected profile")
            Button {
                profileToDelete = harness.selectedProfile
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(renameDeleteDisabled(harness))
            .help("Delete the selected profile")

            distributionMenu(harness: harness)
        }
    }

    /// Distribution actions, grouped in one menu so the Refresh/Clone/Rename/
    /// Delete strip stays uncluttered. Gated behind ``distributionsAvailable``;
    /// below the gate the in-surface `capabilityBanner` explains why.
    @ViewBuilder
    private func distributionMenu(harness: ProfilesHarness) -> some View {
        Menu {
            Button { harness.beginInstall() } label: {
                Label("Install…", systemImage: "square.and.arrow.down")
            }
            .help("Install a distribution from a git URL or local directory")

            Button { showingImporter = true } label: {
                Label("Import…", systemImage: "tray.and.arrow.down")
            }
            .help("Import a profile from a .tar.gz archive")

            if let selected = harness.selectedProfile {
                Divider()
                Button { Task { await harness.update(name: selected.name, forceConfig: false) } } label: {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Re-pull “\(selected.name)” from its recorded source")

                Button { Task { await harness.update(name: selected.name, forceConfig: true) } } label: {
                    Label("Update (overwrite config)", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Update “\(selected.name)”, also overwriting its config.yaml")

                Button { Task { await harness.export(name: selected.name) } } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Export “\(selected.name)” to a .tar.gz archive")

                Button { harness.beginAuthorManifest(name: selected.name) } label: {
                    Label("Edit distribution.yaml & Publish…", systemImage: "square.and.pencil")
                }
                .help("Author “\(selected.name)”’s distribution.yaml and publish to git")
            }
        } label: {
            Label("Distribution", systemImage: "shippingbox")
        }
        .menuIndicator(.visible)
        .disabled(!distributionsAvailable || harness.busy)
        .help("Install, update, export, author and publish profile distributions")
    }

    /// Rename/Delete act on a single named profile and `default` is immutable,
    /// so both are gated on a non-default selection.
    private func renameDeleteDisabled(_ harness: ProfilesHarness) -> Bool {
        guard let profile = harness.selectedProfile else { return true }
        return profile.isDefault || profile.name == HermesProfiles.defaultProfileName
    }

    /// Title for the pushed iPhone editor page, matching whichever secondary
    /// mode is active. nil when the pane is hidden.
    private func editorTitle(_ harness: ProfilesHarness) -> String? {
        if harness.manifestEditor != nil { return "distribution.yaml" }
        if harness.installDraft != nil { return "Install distribution" }
        if harness.viewingManifest { return "Manifest" }
        switch harness.draft?.mode {
        case let .clone(source): return "Clone “\(source)”"
        case let .rename(original): return "Rename “\(original)”"
        case nil: return nil
        }
    }

    // Rendered only while a secondary mode is active — `PlatformSplit`'s
    // `showsSecondary` gate hides this pane entirely otherwise. Priority:
    // author/publish editor → install form → manifest view → clone/rename.
    @ViewBuilder
    private func editorPane(harness: ProfilesHarness) -> some View {
        if harness.manifestEditor != nil {
            ManifestEditorView(
                state: Binding(
                    get: { harness.manifestEditor ?? ManifestEditorState(profileName: "") },
                    set: { harness.manifestEditor = $0 }
                ),
                busy: harness.busy,
                lastOutput: harness.lastOutput,
                canPublish: hostShell != nil && runner != nil,
                onSave: { Task { await harness.saveManifest() } },
                onPublish: { Task { await harness.publish() } },
                onCancel: { harness.closeSecondary() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if harness.installDraft != nil {
            InstallFormView(
                draft: Binding(
                    get: { harness.installDraft ?? InstallDraft() },
                    set: { harness.installDraft = $0 }
                ),
                busy: harness.busy,
                onInstall: { Task { await harness.installDistribution() } },
                onCancel: { harness.closeSecondary() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if harness.viewingManifest {
            ManifestInfoView(
                info: harness.selectedInfo,
                loading: harness.infoLoading,
                error: harness.infoError,
                onAuthor: runner == nil ? nil : {
                    if let name = harness.selectedProfile?.name {
                        harness.beginAuthorManifest(name: name)
                    }
                }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if harness.draft != nil {
            ProfileDraftEditor(
                draft: Binding(
                    get: { harness.draft ?? ProfileDraft(mode: .clone(source: HermesProfiles.defaultProfileName)) },
                    set: { harness.draft = $0 }
                ),
                onSave: { draft in
                    switch draft.mode {
                    case .clone:
                        Task { await harness.clone(newName: draft.newName) }
                    case let .rename(original):
                        Task { await harness.rename(from: original, to: draft.newName) }
                    }
                },
                onCancel: { harness.cancelEdit() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ProfileDraftEditor: View {
    @Binding var draft: ProfileDraft
    let onSave: (ProfileDraft) -> Void
    let onCancel: () -> Void

    private var title: String {
        switch draft.mode {
        case let .clone(source): return "Clone “\(source)”"
        case let .rename(original): return "Rename “\(original)”"
        }
    }

    private var actionLabel: String {
        switch draft.mode {
        case .clone: return "Clone"
        case .rename: return "Rename"
        }
    }

    var body: some View {
        Form {
            Section(title) {
                TextField("New name", text: $draft.newName)
                    .textFieldStyle(.roundedBorder)
                Text("Lowercase letters, digits, “-” or “_”. Starts with a letter or digit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button(actionLabel) { onSave(draft) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Distribution form models

/// Install-from-source form fields.
struct InstallDraft: Equatable {
    var source: String = ""
    var name: String = ""
    var alias: Bool = false
    var force: Bool = false
}

/// Editable mirror of ``DistributionManifest`` (string fields plus identified
/// env rows) for the SwiftUI author form, converted on save.
struct ManifestFields: Equatable {
    var name = ""
    var version = ""
    var description = ""
    var author = ""
    var license = ""
    var hermesRequires = ""
    var envRequires: [EnvRow] = []
    /// Newline-separated list of distribution-owned paths.
    var distributionOwned = ""

    init(name: String = "") { self.name = name }

    init(_ manifest: DistributionManifest) {
        name = manifest.name
        version = manifest.version ?? ""
        description = manifest.description ?? ""
        author = manifest.author ?? ""
        license = manifest.license ?? ""
        hermesRequires = manifest.hermesRequires ?? ""
        envRequires = manifest.envRequires.map { EnvRow($0) }
        distributionOwned = (manifest.distributionOwned ?? []).joined(separator: "\n")
    }

    func toManifest() -> DistributionManifest {
        func clean(_ s: String) -> String? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let owned = distributionOwned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return DistributionManifest(
            name: name.trimmingCharacters(in: .whitespaces),
            version: clean(version),
            description: clean(description),
            author: clean(author),
            license: clean(license),
            hermesRequires: clean(hermesRequires),
            envRequires: envRequires.compactMap { $0.toRequirement() },
            distributionOwned: owned.isEmpty ? nil : owned
        )
    }
}

/// One editable `env_requires` row.
struct EnvRow: Equatable, Identifiable {
    let id = UUID()
    var name = ""
    var description = ""
    var required = true
    /// Fallback value for an optional var (`default` in the manifest).
    var defaultValue = ""

    init() {}

    init(_ requirement: EnvRequirement) {
        name = requirement.name
        description = requirement.description ?? ""
        required = requirement.required
        defaultValue = requirement.defaultValue ?? ""
    }

    func toRequirement() -> EnvRequirement? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        // `default` only applies to optional vars; drop it for required ones.
        let def = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return EnvRequirement(
            name: trimmed,
            description: desc.isEmpty ? nil : desc,
            required: required,
            defaultValue: (required || def.isEmpty) ? nil : def
        )
    }
}

/// Author + publish state for a profile's `distribution.yaml`.
struct ManifestEditorState: Equatable {
    let profileName: String
    var fields = ManifestFields()
    var remoteURL = ""
    var version = ""
    var commitMessage = ""
    /// Set after a successful save, for the confirmation line.
    var lastSaved = false
}

/// A produced `.tar.gz` awaiting the `.fileExporter` save panel.
struct ExportPayload: Equatable {
    var document: TarGzDocument
    var filename: String
}

extension UTType {
    /// `.tar.gz` archive; falls back through gzip to plain data so the picker
    /// still works on systems that don't resolve the compound extension.
    static var tarGZ: UTType {
        UTType(filenameExtension: "gz") ?? .gzip
    }
}

/// `FileDocument` wrapper around already-produced archive bytes, so the
/// `.fileExporter` can save a `.tar.gz` hermes exported on the host.
struct TarGzDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] { [.tarGZ, .gzip, .data] }
    static var writableContentTypes: [UTType] { [.tarGZ, .gzip, .data] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A labeled text field for the Form: the short `label` is the field name (the
/// leading column on macOS), and `prompt` is the example placeholder shown
/// *inside* the box. Labels are kept short so the leading column doesn't squeeze
/// the field in the narrow secondary pane.
@ViewBuilder
private func labeledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
    TextField(label, text: text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder)
}

// MARK: - Install form

private struct InstallFormView: View {
    @Binding var draft: InstallDraft
    let busy: Bool
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("Install distribution") {
                labeledField("Source", text: $draft.source, prompt: "git URL or local directory")
                labeledField("Name", text: $draft.name, prompt: "optional — defaults to repo name")
                Toggle("Record source as an alias", isOn: $draft.alias)
                Toggle("Overwrite an existing profile", isOn: $draft.force)
                Label(
                    "Distributions are unsigned third-party content. Only install from sources you trust.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Install") { onInstall() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(busy || draft.source.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Manifest view (read-only)

private struct ManifestInfoView: View {
    let info: ProfileDistributionInfo?
    let loading: Bool
    /// Non-nil when the read failed (vs. the profile simply not being a
    /// distribution), so the pane reports the error instead of "no manifest".
    let error: String?
    /// Opens the author/publish editor for the viewed profile. nil hides the
    /// "Author one" affordance (e.g. no CLI runner).
    let onAuthor: (() -> Void)?

    var body: some View {
        if loading {
            ProgressView("Reading manifest…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("Couldn’t read the manifest", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if let info, info.isDistribution {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headline(info)
                    if !info.envRequires.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Required environment").font(.headline)
                            ForEach(info.envRequires) { req in
                                HStack(spacing: 6) {
                                    EntityLink(req.name, ref: .envVar(name: req.name), style: .prominent)
                                    if !req.required {
                                        Text("optional").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let description = req.description, !description.isEmpty {
                                        Text("— \(description)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !info.rawText.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("distribution.yaml").font(.headline)
                            Text(info.rawText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView {
                Label("Not a distribution", systemImage: "shippingbox")
            } description: {
                Text("This profile has no distribution.yaml yet.")
            } actions: {
                if let onAuthor {
                    Button {
                        onAuthor()
                    } label: {
                        Label("Author distribution.yaml", systemImage: "square.and.pencil")
                    }
                    .help("Create a distribution.yaml for this profile and publish it")
                }
            }
        }
    }

    @ViewBuilder
    private func headline(_ info: ProfileDistributionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = info.name { row("Name", name) }
            if let version = info.version { row("Version", version) }
            if let description = info.description { row("Description", description) }
            if let author = info.author { row("Author", author) }
            if let license = info.license { row("License", license) }
            if let hermesRequires = info.hermesRequires { row("Requires", hermesRequires) }
            if let source = info.source { row("Source", source) }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }
}

// MARK: - Manifest author / publish editor

private struct ManifestEditorView: View {
    @Binding var state: ManifestEditorState
    let busy: Bool
    let lastOutput: String?
    let canPublish: Bool
    let onSave: () -> Void
    let onPublish: () -> Void
    let onCancel: () -> Void

    /// Width of the right-aligned label column. Sized for the longest field
    /// label ("Hermes version" / "Remote URL").
    private let labelWidth: CGFloat = 110

    var body: some View {
        // Hand-rolled layout (not `Form`): a macOS `Form` reserves its leading
        // column only for recognized labeled controls and indents every other
        // row to the field column — so section headers couldn't reach the
        // leading margin. Here headers are flush-left `Text` and field rows pair
        // a fixed-width trailing label with the field, so the headers sit to the
        // left of the label column exactly as intended.
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                heading("Manifest", emphasized: true)
                field("Name", text: $state.fields.name, prompt: "my-distribution")
                field("Version", text: $state.fields.version, prompt: "1.0.0")
                field("Description", text: $state.fields.description, prompt: "What this distribution does")
                field("Author", text: $state.fields.author, prompt: "Your name")
                field("License", text: $state.fields.license, prompt: "MIT")
                field("Hermes version", text: $state.fields.hermesRequires, prompt: ">=0.15.0")

                heading("Required environment", emphasized: false)
                ForEach($state.fields.envRequires) { $row in
                    VStack(spacing: 4) {
                        HStack {
                            plainField(text: $row.name, prompt: "VAR_NAME", accessibility: "Variable name")
                            Toggle("Required", isOn: $row.required)
                                .help("Whether the installer must supply this variable")
                            Button(role: .destructive) {
                                state.fields.envRequires.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this variable")
                        }
                        plainField(text: $row.description, prompt: "description (optional)", accessibility: "Description")
                        // `default` is the fallback when an optional var isn't
                        // supplied — only meaningful (and only written) when the
                        // var is optional.
                        if !row.required {
                            plainField(text: $row.defaultValue, prompt: "default value when not provided", accessibility: "Default value")
                        }
                    }
                    .padding(.leading, labelWidth + 8)
                }
                Button {
                    state.fields.envRequires.append(EnvRow())
                } label: {
                    Label("Add variable", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add a required environment variable")
                .padding(.leading, labelWidth + 8)

                heading("Distribution-owned files", emphasized: false)
                TextEditor(text: $state.fields.distributionOwned)
                    .font(.caption.monospaced())
                    .frame(minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                Text("One path per line. These are overwritten on update rather than preserved.")
                    .font(.caption).foregroundStyle(.secondary)

                // Everything above is the distribution.yaml manifest; the fields
                // below configure git publishing and are NOT written to the manifest.
                Divider().padding(.vertical, 4)

                heading("Publish to git", emphasized: true)
                field("Remote URL", text: $state.remoteURL, prompt: "git@github.com:you/dist.git")
                field("Tag", text: $state.version, prompt: "v1.0.0")
                field("Message", text: $state.commitMessage, prompt: "Publish v1.0.0")
                if !canPublish {
                    Text("Publishing needs the Hermes CLI and host access for this profile.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { onPublish() } label: {
                    Label("Publish", systemImage: "paperplane")
                }
                .disabled(busy || !canPublish
                    || state.remoteURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || state.version.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Commit, tag and push the distribution to the git remote")

                if let lastOutput {
                    heading("Result", emphasized: false)
                    Text(lastOutput).font(.caption.monospaced()).textSelection(.enabled)
                }

                HStack {
                    Button("Cancel", role: .cancel) { onCancel() }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Save distribution.yaml") { onSave() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(busy || state.fields.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A flush-left heading row. `emphasized` titles (Manifest, Publish to git)
    /// read as headings like other screens; the rest are quieter sub-labels.
    @ViewBuilder
    private func heading(_ title: String, emphasized: Bool) -> some View {
        Text(title)
            .font(emphasized ? .headline : .subheadline)
            .foregroundStyle(emphasized ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, emphasized ? 8 : 4)
    }

    /// A field row: a fixed-width, right-aligned label (the field name) outside
    /// the box, with the example value as the in-box placeholder.
    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            plainField(text: text, prompt: prompt, accessibility: label)
        }
    }

    /// A bare placeholder-only text field (no leading label column).
    @ViewBuilder
    private func plainField(text: Binding<String>, prompt: String, accessibility: String) -> some View {
        TextField(accessibility, text: text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
    }
}
