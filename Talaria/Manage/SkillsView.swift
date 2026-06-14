import HermesKit
import SwiftUI

/// Which lifecycle actions a row offers, derived from `hermes skills list`.
/// `hub` → Update / Audit / Remove; `builtin` → Reset (+ Repair when official);
/// `local` → Publish. `nil` (unknown / no admin runner) offers none.
enum SkillKind {
    case hub
    case local
    case builtin
}

/// A captured `skills audit` report awaiting presentation in a sheet.
struct SkillAuditReport: Identifiable {
    let name: String
    let text: String
    var id: String { name }
}

/// Failures specific to the remote (host-shell) Force-remove path.
enum SkillForceRemoveError: LocalizedError {
    case notLocated
    case remoteShellUnavailable
    case remoteCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLocated:
            return "Couldn't locate this skill's directory on disk; nothing was removed."
        case .remoteShellUnavailable:
            return "Force remove is unavailable: no shell on the remote host."
        case .remoteCommandFailed(let detail):
            return detail
        }
    }
}

@MainActor
@Observable
final class SkillsHarness {
    // Dashboard-backed installed list + enabled state (the table's source).
    var rows: [DashboardSkill] = []
    var isLoading: Bool = false
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// ``bannerKey`` so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?
    /// Surface id used to key this list's banners ("skills"), set by the view.
    var bannerKey: String = "list"
    var selectionID: String?
    var toggling: Set<String> = []

    // Skills Hub search (HTTP catalog — works without the admin runner).
    var searchQuery: String = ""
    var searchResults: [HubCatalogSkill] = []
    var searching: Bool = false
    var catalogError: String?
    /// The query that actually produced `searchResults`. Lets the UI tell
    /// "searched and found nothing" apart from "haven't searched this text yet",
    /// so the empty-state copy only shows once a search has really run.
    var lastSearchedQuery: String?

    // Install-from-identifier form.
    var installIdentifier: String = ""
    /// Identifier currently installing (from either the search list or the
    /// manual form), so exactly that row/button shows progress and disables.
    var installingIdentifier: String?
    /// Green confirmation line shown after a successful install; cleared when
    /// the next install starts.
    var lastInstallMessage: String?

    /// Names of installed skills that came from the hub (eligible for Update /
    /// Remove), derived from `hermes skills list`. Empty when no admin runner.
    var hubInstalledNames: Set<String> = []
    /// Names of installed skills whose Source is exactly `local` (user-created,
    /// neither builtin nor Hub), derived from the same `hermes skills list`.
    /// Empty when no admin runner.
    var localNames: Set<String> = []
    /// Hub skills with an upstream update available (from `hermes skills check`),
    /// populated off `refresh()` so each row can flag "Update available".
    var updatableNames: Set<String> = []
    /// Names whose Source is exactly `builtin` (shipped with Hermes), eligible
    /// for Reset (and Repair when also official). Empty when no admin runner.
    var builtinNames: Set<String> = []
    /// Names whose Trust is `official` — the subset of builtins eligible for the
    /// `repair-official` action. Empty when no admin runner.
    var officialNames: Set<String> = []
    /// Names with an in-flight per-skill action (update/audit/reset/repair/
    /// remove/publish), to disable their buttons.
    var busy: Set<String> = []
    /// Single in-flight flag for the global bundled-seeding actions
    /// (opt-out / opt-in / resync), which aren't keyed by a skill name.
    var seedingBusy: Bool = false
    /// Captured `skills audit` report awaiting presentation; cleared on dismiss.
    var auditReport: SkillAuditReport?
    /// Previewed local built-in skill resync plan awaiting confirmation.
    var resyncPlan: BundledSkillsResyncPlan?

    private let client: DashboardClient
    let runner: HermesAdminRunning?
    private let catalog: SkillsHubCatalog
    /// The window's profile — its `hermesHome` resolves the on-disk skills root
    /// (Publish / Force remove), and it drives the `SKILL.md` preview read
    /// (local or remote SSH via ``HermesFileStore``).
    let profile: ServerProfile?
    /// Remote file transport for the preview read on SSH profiles; nil/unused
    /// for local profiles.
    let transfer: RemoteSnapshotTransfer?
    /// Host shell on the profile's host (local `/bin/sh` or remote SSH), used to
    /// `rm -rf` a skill directory on a **remote** profile (the local path uses
    /// `FileManager`). nil disables remote Force remove.
    let hostShell: HostShellRunning?

    /// SKILL.md preview for the selected skill (raw markdown, highlighted in the
    /// detail panel). `previewName` keys the load so a slow read for a since-
    /// deselected skill can't overwrite the current one.
    var previewName: String?
    var previewText: String?
    var previewError: String?
    var previewLoading: Bool = false
    /// The selected skill's real on-disk directory (resolved by matching its
    /// `SKILL.md` frontmatter name — the dashboard `name` is *not* the directory
    /// name). Keyed by `resolvedDirName`; drives the Force-remove confirmation
    /// path and is reused by Publish. nil when not yet resolved or not found.
    var resolvedDir: String?
    var resolvedDirName: String?

    init(
        client: DashboardClient,
        runner: HermesAdminRunning?,
        profile: ServerProfile? = nil,
        transfer: RemoteSnapshotTransfer? = nil,
        hostShell: HostShellRunning? = nil,
        catalog: SkillsHubCatalog = SkillsHubCatalog()
    ) {
        self.client = client
        self.runner = runner
        self.profile = profile
        self.transfer = transfer
        self.hostShell = hostShell
        self.catalog = catalog
    }

    /// The local skills root (`<hermesHome>/skills`, default `~/.hermes/skills`).
    var skillsRoot: URL { HermesSkillsFileStore.localSkillsRoot(hermesHome: profile?.hermesHome) }

    /// The currently-selected installed skill, or nil. Drives the detail panel.
    var selected: DashboardSkill? { rows.first { $0.name == selectionID } }

    /// The on-disk directory a skill occupies (`<hermesHome>/skills/[<category>/]
    /// <name>`). Local resolves to an absolute path; remote keeps `~` literal
    /// (the remote side resolves it). Used for the Force-remove confirmation and
    /// as the unexpanded base for ``resolvedPublishPath``.
    func skillDirectoryPath(for skill: DashboardSkill) -> String {
        switch profile?.kind {
        case .ssh:
            let home = profile?.hermesHome?.trimmingCharacters(in: .whitespaces)
            var path = (home?.isEmpty == false ? home! : "~/.hermes") + "/skills"
            if let category = skill.category, !category.isEmpty { path += "/\(category)" }
            return path + "/\(skill.name)"
        case .local, .none:
            var url = skillsRoot
            if let category = skill.category, !category.isEmpty {
                url.appendPathComponent(category, isDirectory: true)
            }
            url.appendPathComponent(skill.name, isDirectory: true)
            return url.path
        }
    }

    /// True when the window's profile runs Hermes on this machine (so deletes use
    /// `FileManager` and reads/`find` resolve against the local home).
    var isLocalProfile: Bool {
        switch profile?.kind {
        case .local: return true
        case .ssh, .none: return false
        }
    }

    /// Resolves the selected skill's **real** on-disk directory by matching its
    /// `SKILL.md` frontmatter `name` — because the dashboard `name` is that
    /// frontmatter value, not the directory name (e.g. dir `creative-ideation`
    /// has `name: ideation`). Lists the candidate dirs in the skill's (reliable)
    /// category via the host shell, then reads each candidate's `SKILL.md` — the
    /// matching-named candidate first, so the common `name == dir` case is one
    /// read — until the frontmatter name matches. Returns the absolute directory,
    /// or nil if it can't be located. Authoritative: the returned dir's `SKILL.md`
    /// is verified to belong to this skill, so destructive actions never target a
    /// guessed path.
    func resolveSkillDirectory(for skill: DashboardSkill) async -> String? {
        guard let profile, let hostShell else { return nil }
        let command: String
        do {
            command = try HermesSkillsFileStore.skillCandidateListingCommand(
                hermesHome: profile.hermesHome, category: skill.category
            )
        } catch {
            return nil
        }
        guard let listing = try? await hostShell.runShell(command, workingDirectory: nil),
              listing.exitCode == 0 else { return nil }
        var candidates = HermesSkillsFileStore.parseDirectoryListing(listing.stdout)
        // Try the directory whose name equals the skill name first (the common
        // case), so `name == dir` resolves in a single read.
        if let exactIndex = candidates.firstIndex(where: { ($0 as NSString).lastPathComponent == skill.name }) {
            candidates.insert(candidates.remove(at: exactIndex), at: 0)
        }
        for dir in candidates.prefix(60) {
            let skillMd = (dir as NSString).appendingPathComponent("SKILL.md")
            guard let content = try? await HermesFileStore.read(
                resolvedPath: skillMd, isLocal: isLocalProfile, transfer: transfer, profile: profile
            ) else { continue }
            if HermesSkillsFileStore.frontmatterName(content) == skill.name {
                return dir
            }
        }
        return nil
    }

    /// The Publish sheet's pre-filled path. Prefers the resolved on-disk
    /// directory (authoritative); falls back to a best-effort constructed path
    /// (editable in the sheet) when the directory can't be located — for remote,
    /// normalizing `~`/`$HOME`/`${HOME}`/absolute `hermesHome` and prepending the
    /// resolved remote `$HOME` so `hermes skills publish` gets an absolute path.
    func resolvedPublishPath(for skill: DashboardSkill) async -> String {
        // Reuse the directory `loadPreview` already resolved for this skill rather
        // than re-running the find + SKILL.md reads (extra SSH round-trips). Publish
        // isn't destructive, so the cached value is fine; Force remove deliberately
        // re-resolves fresh.
        if resolvedDirName == skill.name, let dir = resolvedDir { return dir }
        if let dir = await resolveSkillDirectory(for: skill) { return dir }
        switch profile?.kind {
        case .ssh:
            var resolvedHome: String?
            if let hostShell,
               let result = try? await hostShell.runShell("command printf '%s' \"$HOME\"", workingDirectory: nil),
               result.exitCode == 0 {
                let home = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                resolvedHome = home.isEmpty ? nil : home
            }
            return HermesSkillsFileStore.remoteSkillPath(
                hermesHome: profile?.hermesHome,
                category: skill.category,
                name: skill.name,
                homeDirectory: resolvedHome
            )
        case .local, .none:
            return skillDirectoryPath(for: skill)
        }
    }

    /// Resolves the selected skill's directory, reads its `SKILL.md`, and renders
    /// the preview. Runs on selection change (the view's `.task(id:)` cancels the
    /// prior load), re-checking the selection after each `await` so a stale read
    /// can't overwrite. Also caches the resolved directory (`resolvedDir`) for the
    /// Force-remove confirmation. Best-effort: a missing/unlocatable skill shows a
    /// soft note, not a banner error.
    func loadPreview() async {
        guard let skill = selected else {
            previewName = nil
            previewText = nil
            previewError = nil
            previewLoading = false
            resolvedDir = nil
            resolvedDirName = nil
            return
        }
        previewName = skill.name
        previewText = nil
        previewError = nil
        previewLoading = true
        // Guard the clear by `previewName` like the writes below, so the losing
        // side of a fast selection race doesn't drop the spinner while the
        // winning task is still reading.
        defer { if previewName == skill.name { previewLoading = false } }

        let dir = await resolveSkillDirectory(for: skill)
        guard previewName == skill.name else { return }
        resolvedDir = dir
        resolvedDirName = skill.name
        guard let dir else {
            previewError = "Couldn't locate this skill on disk."
            return
        }
        do {
            let skillMd = (dir as NSString).appendingPathComponent("SKILL.md")
            let text = try await HermesFileStore.read(
                resolvedPath: skillMd, isLocal: isLocalProfile, transfer: transfer, profile: profile
            )
            guard previewName == skill.name else { return }
            previewText = text
        } catch {
            guard previewName == skill.name else { return }
            previewError = error.localizedDescription
        }
    }

    /// True once the manual install field has a non-empty identifier.
    var canInstallFromField: Bool {
        !installIdentifier.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isHubManaged(_ name: String) -> Bool { hubInstalledNames.contains(name) }

    func isLocal(_ name: String) -> Bool { localNames.contains(name) }

    /// True when this builtin skill is official-trust (eligible for Repair).
    func isOfficial(_ name: String) -> Bool { officialNames.contains(name) }

    /// Classifies a row so it can pick its lifecycle actions. Returns `nil` when
    /// the skill isn't in the CLI list yet (no admin runner, or a transient
    /// dashboard/CLI mismatch), in which case the row offers no kind-specific
    /// actions.
    func kind(for name: String) -> SkillKind? {
        if hubInstalledNames.contains(name) { return .hub }
        if localNames.contains(name) { return .local }
        if builtinNames.contains(name) { return .builtin }
        return nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await client.listSkills()
            lastError = nil
            banners?.dismiss(key: bannerKey)
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
        await refreshHubInstalled()
        // Probe every hub skill for upstream updates fire-and-forget so the
        // "Update available" badges populate without adding network latency to
        // `refresh()` (which also runs on every enable/disable toggle).
        Task { await refreshUpdatable() }
    }

    /// Populates `hubInstalledNames` from the CLI list when an admin runner is
    /// available. A failure here is non-fatal (search + toggle still work), so
    /// it's recorded to `lastError` only if the dashboard list itself succeeded.
    private func refreshHubInstalled() async {
        guard let runner else {
            hubInstalledNames = []
            localNames = []
            builtinNames = []
            officialNames = []
            return
        }
        do {
            let installed = try await HermesSkillsHub.listInstalled(runner: runner)
            hubInstalledNames = Set(installed.filter(\.isHubManaged).map(\.name))
            localNames = Set(installed.filter(\.isLocal).map(\.name))
            builtinNames = Set(installed.filter(\.isBuiltin).map(\.name))
            officialNames = Set(installed.filter(\.isOfficial).map(\.name))
        } catch {
            hubInstalledNames = []
            localNames = []
            builtinNames = []
            officialNames = []
            if lastError == nil {
                lastError = error.localizedDescription
                banners?.surfaceError(bannerKey, error.localizedDescription)
            }
        }
    }

    func setEnabled(_ name: String, enabled: Bool) async {
        toggling.insert(name)
        defer { toggling.remove(name) }
        do {
            try await client.toggleSkill(name: name, enabled: enabled)
            // Refresh so the row reflects what the server actually persisted —
            // dashboard returns 200 on toggle without a body, so we read back.
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    // MARK: - Search

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            lastSearchedQuery = nil
            return
        }
        searching = true
        defer { searching = false }
        do {
            // First call triggers the cached fetch; subsequent searches in the
            // TTL window hit the in-memory/disk cache.
            _ = try await catalog.skills()
            searchResults = await catalog.search(query)
            lastSearchedQuery = query
            catalogError = nil
        } catch {
            searchResults = []
            lastSearchedQuery = nil
            catalogError = error.localizedDescription
        }
    }

    // MARK: - Mutations (CLI fallback)

    func install(identifier: String, displayName: String? = nil) async {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let runner else { return }
        installingIdentifier = trimmed
        lastInstallMessage = nil
        defer { installingIdentifier = nil }
        do {
            _ = try await HermesSkillsHub.install(runner: runner, identifier: trimmed)
            if installIdentifier.trimmingCharacters(in: .whitespaces) == trimmed {
                installIdentifier = ""
            }
            await refresh()
            let name = displayName ?? trimmed
            lastInstallMessage = "Installed \(name). Available in your next session."
            // Highlight the freshly installed row when the refreshed list
            // contains it, as a visual confirmation.
            if let displayName, rows.contains(where: { $0.name == displayName }) {
                selectionID = displayName
            }
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    func update(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.update(runner: runner, name: name)
            updatableNames.remove(name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Checks every installed hub skill for an upstream update in one
    /// `hermes skills check` call so each row's "Update available" badge can
    /// flag it. Network-bound, so it runs fire-and-forget off `refresh()` and is
    /// best-effort — a slow or failed check leaves the badges absent rather than
    /// surfacing an error on the surface.
    func refreshUpdatable() async {
        guard let runner, !hubInstalledNames.isEmpty else { return }
        do {
            let statuses = try await HermesSkillsHub.checkUpdates(runner: runner)
            updatableNames = Set(statuses.filter(\.updateAvailable).map(\.name))
        } catch {
            // Best-effort hint only — leave `updatableNames` untouched.
        }
    }

    func remove(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await HermesSkillsHub.uninstall(runner: runner, name: name)
            // Drop the selection so the table highlight doesn't dangle on a
            // name that no longer exists after the refresh.
            if selectionID == name { selectionID = nil }
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Force-removes a skill by deleting its **resolved** directory directly —
    /// the fallback for builtin/local skills (which `hermes skills uninstall`
    /// refuses) and for a stuck hub uninstall. Resolves the real directory by
    /// matching its `SKILL.md` frontmatter name (the dashboard `name` is not the
    /// directory name), then deletes it: **local** via `FileManager`
    /// (symlink-aware guard), **remote** via `rm -rf` over the host shell. Refuses
    /// (deletes nothing) if the directory can't be located, so a wrong/guessed
    /// path is never removed.
    func forceRemove(_ skill: DashboardSkill) async {
        guard let profile else { return }
        let name = skill.name
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            guard let dir = await resolveSkillDirectory(for: skill) else {
                throw SkillForceRemoveError.notLocated
            }
            switch profile.kind {
            case .local:
                try HermesSkillsFileStore.forceDeleteDirectory(
                    URL(fileURLWithPath: dir), underSkillsRoot: skillsRoot
                )
            case .ssh:
                guard let hostShell else { throw SkillForceRemoveError.remoteShellUnavailable }
                let command = try HermesSkillsFileStore.remoteForceDeleteDirectoryCommand(directory: dir)
                let result = try await hostShell.runShell(command, workingDirectory: nil)
                guard result.exitCode == 0 else {
                    let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw SkillForceRemoveError.remoteCommandFailed(
                        detail.isEmpty ? "Force remove failed (exit \(result.exitCode))." : detail
                    )
                }
            }
            if selectionID == name { selectionID = nil }
            resolvedDir = nil
            resolvedDirName = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    // MARK: - Lifecycle actions (CLI fallback)

    /// Re-scans a hub skill and captures the report into `auditReport` for the
    /// presentation sheet. Doesn't mutate state, so it skips the post-refresh.
    func audit(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            let report = try await HermesSkillsHub.audit(runner: runner, name: name)
            auditReport = SkillAuditReport(
                name: name,
                text: report.isEmpty ? "Audit completed — no issues reported." : report
            )
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Clears a builtin skill's `user-modified` tracking (safe `skills reset`).
    func reset(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.reset(runner: runner, name: name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Backfills an official skill's hub metadata (safe `skills repair-official`).
    func repair(_ name: String) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.repairOfficial(runner: runner, name: name)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Publishes a local skill directory to a registry. `path` is the on-disk
    /// skill directory (from the publish sheet); `name` keys the busy flag and
    /// the confirmation. Surfaces a success banner on completion.
    func publish(name: String, path: String, registry: SkillsPublishRegistry, repo: String?) async {
        guard let runner else { return }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            _ = try await HermesSkillsHub.publish(runner: runner, path: path, registry: registry, repo: repo)
            banners?.surfaceSuccess(bannerKey, "Published \(name) to \(registry.rawValue).")
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    // MARK: - Bundled-skill seeding (global, not keyed by name)

    /// Stops bundled skills from seeding into this profile (safe `skills
    /// opt-out`). Guards the shared `seedingBusy` flag.
    func optOut() async {
        await runSeeding { try await HermesSkillsHub.optOut(runner: $0) }
    }

    /// Re-enables bundled-skill seeding (`skills opt-in`).
    func optIn() async {
        await runSeeding { try await HermesSkillsHub.optIn(runner: $0) }
    }

    /// Builds a local filesystem preview against `~/.hermes/hermes-agent/skills`
    /// without mutating the profile's skills tree.
    func previewBundledResync() async {
        guard !seedingBusy else { return }
        guard isLocalProfile else {
            let message = "Built-in skill resync is available only for local Hermes profiles."
            lastError = message
            banners?.surfaceError(bannerKey, message)
            return
        }
        seedingBusy = true
        defer { seedingBusy = false }
        do {
            let skillsRoot = self.skillsRoot
            resyncPlan = try await Task.detached {
                try BundledSkillsResyncService(skillsRoot: skillsRoot).preview()
            }.value
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Applies the exact previewed resync plan, then refreshes the dashboard
    /// list so new/updated skills appear in the installed table.
    func applyBundledResync(_ plan: BundledSkillsResyncPlan) async {
        guard !seedingBusy else { return }
        seedingBusy = true
        defer { seedingBusy = false }
        do {
            let skillsRoot = self.skillsRoot
            let result = try await Task.detached {
                try BundledSkillsResyncService(skillsRoot: skillsRoot).apply(plan)
            }.value
            resyncPlan = nil
            await refresh()
            let skipped = result.skipped.count
            var parts = ["\(result.added.count) added", "\(result.updated.count) updated", "\(skipped) skipped"]
            if let commit = result.sourceCommit?.prefix(12) {
                parts.append("source \(commit)")
            }
            banners?.surfaceSuccess(bannerKey, "Resynced built-in skills: \(parts.joined(separator: ", ")).")
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }

    /// Shared driver for the three bundled-seeding actions: single in-flight
    /// guard, run the closure, refresh on success, route errors to the banner.
    private func runSeeding(_ body: @escaping (HermesAdminRunning) async throws -> String) async {
        guard let runner, !seedingBusy else { return }
        seedingBusy = true
        defer { seedingBusy = false }
        do {
            _ = try await body(runner)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            banners?.surfaceError(bannerKey, error.localizedDescription)
        }
    }
}

struct SkillsView: View {
    let client: DashboardClient?
    let runner: HermesAdminRunning?
    let hermesVersion: HermesVersion?
    let profile: ServerProfile?
    let transfer: RemoteSnapshotTransfer?
    let hostShell: HostShellRunning?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: a skill `EntityLink` (e.g. from a chat permission
    /// prompt) selects its row when this tab lands. Optional so the view renders
    /// without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: SkillsHarness?
    // Both hub sections collapse by default so the installed list owns the
    // pane; the user expands them on demand to search or paste an identifier.
    @State private var searchExpanded = false
    @State private var installExpanded = false
    /// The local skill currently being published (drives the publish sheet), or
    /// `nil` when no sheet is up.
    @State private var publishTarget: PublishTarget?
    /// Confirms the destructive-ish opt-out from the Bundled skills menu.
    @State private var confirmingOptOut = false

    init(
        client: DashboardClient?,
        runner: HermesAdminRunning? = nil,
        hermesVersion: HermesVersion? = nil,
        profile: ServerProfile? = nil,
        transfer: RemoteSnapshotTransfer? = nil,
        hostShell: HostShellRunning? = nil
    ) {
        self.client = client
        self.runner = runner
        self.hermesVersion = hermesVersion
        self.profile = profile
        self.transfer = transfer
        self.hostShell = hostShell
    }

    /// Whether the Skills Hub install/update affordances can run: they need the
    /// CLI admin runner and work over any transport (local or remote SSH/NIO).
    private var mutationsAvailable: Bool { runner != nil }

    /// Whether **Remove** can run. `hermes skills uninstall` has no `--yes` in
    /// v0.14.0 and is confirmed by feeding `y\n` on stdin — only the local macOS
    /// runner delivers stdin to the child, so remote (SSH/NIO) profiles can't
    /// uninstall yet. Gate Remove (not Install/Update) on that capability rather
    /// than letting a remote uninstall read closed stdin and fail with a
    /// confusing "Cancelled." error.
    private var removeAvailable: Bool { runner?.deliversStdin == true }

    /// Whether the lifecycle affordances (Audit / Reset / Repair / Publish and
    /// the Bundled skills menu) can run: they need the CLI admin runner and a
    /// Hermes new enough to expose the subcommands. Below the gate the
    /// in-surface `capabilityBanner` explains why; runtime `commandUnavailable`
    /// is the real backstop.
    private var lifecycleAvailable: Bool {
        runner != nil && CapabilityTable().has(.skillsLifecycle, in: hermesVersion)
    }

    /// Whether **Publish** can run. `hermes skills publish` is a plain CLI
    /// command (no stdin, no local filesystem) that runs on whichever host the
    /// runner targets, so it works on local **and** remote — same gate as
    /// Update/Audit (a runner plus the lifecycle capability).
    private var publishAvailable: Bool { mutationsAvailable }

    /// Whether **Force remove** can run. It needs a host shell for *both* kinds:
    /// to list candidate directories while resolving the skill (`find`), and —
    /// on remote — to `rm -rf` (local deletes via `FileManager`). So the gate is
    /// a host shell regardless of profile kind, keeping the invariant explicit and
    /// fail-safe if the runner construction ever changes.
    private var forceRemoveAvailable: Bool {
        profile != nil && hostShell != nil
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "wand.and.stars",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Skills")
        .dismissesBanner("skills", from: banners)
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil, not only on
        // first appear (a bare `.task` on the Group never re-runs for that flip).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { consumeFocus(harness: harness!); return }
            let h = SkillsHarness(
                client: client, runner: runner, profile: profile, transfer: transfer, hostShell: hostShell
            )
            h.banners = banners
            h.bannerKey = "skills"
            harness = h
            await h.refresh()
            consumeFocus(harness: h)
        }
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
    }

    /// Selects the row named by a pending skill focus, then clears it. Ignores
    /// focus aimed at another tab/page.
    private func consumeFocus(harness: SkillsHarness) {
        guard let ref = navigator?.pendingFocus, case let .skill(id) = ref else { return }
        if harness.rows.contains(where: { $0.name == id }) {
            harness.selectionID = id
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: SkillsHarness) -> some View {
        // Reachable only from the desktop window's Browse sidebar (macOS +
        // iPad); the iPhone shell has no Browse, so this never renders there.
        // A master/detail split: the installed-skills list on the left, the
        // selected skill's description, actions, and SKILL.md preview on the right.
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.selected != nil },
                set: { if !$0 { harness.selectionID = nil } }
            ),
            secondaryTitle: harness.selected?.name
        ) {
            primaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await harness.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(harness.isLoading)
                .help("Refresh the skills list")
            }
            ToolbarItem {
                bundledSkillsMenu(harness: harness)
            }
        }
        // Hard errors route to the top-of-window strip; only the capability warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .requiresDashboard,
                feature: "Skills via Hermes dashboard",
                version: hermesVersion
            )
                ?? capabilityBanner(
                    .skillsHub,
                    feature: "Installing, updating and removing Skills Hub skills",
                    version: hermesVersion
                )
                ?? capabilityBanner(
                    .skillsLifecycle,
                    feature: "Auditing, resetting, repairing, publishing and bundled-skill opt-in/out",
                    version: hermesVersion
                ),
            severity: .warning
        )
        .alert("Opt out of bundled skills?", isPresented: $confirmingOptOut) {
            Button("Cancel", role: .cancel) {}
            Button("Opt out") { Task { await harness.optOut() } }
        } message: {
            Text("Stops built-in skills from seeding into this profile. Already-installed copies are left in place.")
        }
        .sheet(item: $publishTarget) { target in
            PublishSheet(skillName: target.skillName, defaultPath: target.path) { path, registry, repo in
                Task { await harness.publish(name: target.skillName, path: path, registry: registry, repo: repo) }
            }
        }
        .sheet(item: Binding(
            get: { harness.auditReport },
            set: { harness.auditReport = $0 }
        )) { report in
            AuditReportSheet(report: report)
        }
        .sheet(isPresented: Binding(
            get: { harness.resyncPlan != nil },
            set: { if !$0 { harness.resyncPlan = nil } }
        )) {
            if let plan = harness.resyncPlan {
                BundledSkillsResyncSheet(plan: plan) {
                    Task { await harness.applyBundledResync(plan) }
                }
            }
        }
        // Load the selected skill's SKILL.md preview; re-fires (and cancels the
        // prior load) whenever the selection changes.
        .task(id: harness.selectionID) {
            await harness.loadPreview()
        }
    }

    /// Bundled-skill seeding actions, grouped in one toolbar menu. Gated behind
    /// ``lifecycleAvailable``; below the gate the in-surface `capabilityBanner`
    /// explains why.
    @ViewBuilder
    private func bundledSkillsMenu(harness: SkillsHarness) -> some View {
        Menu {
            Button {
                confirmingOptOut = true
            } label: {
                Label("Opt out of bundled skills", systemImage: "xmark.circle")
            }
            .help("Stops built-in skills from seeding into this profile")

            Button {
                Task { await harness.optIn() }
            } label: {
                Label("Opt back in", systemImage: "checkmark.circle")
            }
            .help("Re-enables seeding of built-in skills into this profile")

            Button {
                Task { await harness.previewBundledResync() }
            } label: {
                Label("Resync built-in skills", systemImage: "arrow.clockwise.circle")
            }
            .help("Preview and copy built-in skills from the local Hermes source checkout")
        } label: {
            Label("Bundled skills", systemImage: "shippingbox")
        }
        .menuIndicator(.visible)
        .disabled(!lifecycleAvailable || harness.seedingBusy)
        .help("Opt in or out of seeding Hermes' built-in skills into this profile")
    }

    // MARK: - Primary pane (search + install form + table)

    @ViewBuilder
    private func primaryPane(harness: SkillsHarness) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                searchSection(harness: harness)
                Divider()
                installSection(harness: harness)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            skillsList(harness: harness)
        }
    }

    @ViewBuilder
    private func searchSection(harness: SkillsHarness) -> some View {
        DisclosureGroup(isExpanded: $searchExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search by name, description or tag", text: Binding(
                        get: { harness.searchQuery },
                        set: { harness.searchQuery = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await harness.search() } }
                    if harness.searching {
                        ProgressView().controlSize(.small)
                    }
                    Button("Search") {
                        Task { await harness.search() }
                    }
                    .disabled(harness.searching
                        || harness.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let error = harness.catalogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                searchResults(harness: harness)
            }
            .padding(.top, 4)
        } label: {
            Text("Search the Skills Hub").font(.headline)
        }
    }

    @ViewBuilder
    private func searchResults(harness: SkillsHarness) -> some View {
        if harness.searchResults.isEmpty {
            // Only after a search actually ran for the *current* text — not
            // while the user is still typing a query they haven't submitted.
            if !harness.searching,
               harness.catalogError == nil,
               harness.lastSearchedQuery == harness.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                Text("No matching skills.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            // Bounded height so a long result list scrolls within the section
            // rather than pushing the installed-skills table off-screen.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(harness.searchResults) { result in
                        SkillSearchRow(
                            result: result,
                            installed: harness.rows.contains(where: { $0.name == result.name }),
                            installing: harness.installingIdentifier == result.identifier,
                            canInstall: mutationsAvailable && harness.installingIdentifier == nil,
                            onInstall: {
                                Task { await harness.install(identifier: result.identifier, displayName: result.name) }
                            }
                        )
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    @ViewBuilder
    private func installSection(harness: SkillsHarness) -> some View {
        DisclosureGroup(isExpanded: $installExpanded) {
            Form {
                TextField("official/… or https://…/SKILL.md", text: Binding(
                    get: { harness.installIdentifier },
                    set: { harness.installIdentifier = $0 }
                ))
                HStack(spacing: 8) {
                    if let message = harness.lastInstallMessage {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(2)
                    }
                    if !mutationsAvailable {
                        Text("Admin runner unavailable — search still works.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if harness.installingIdentifier != nil { ProgressView().controlSize(.small) }
                    Button("Install") {
                        Task { await harness.install(identifier: harness.installIdentifier) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!mutationsAvailable || harness.installingIdentifier != nil || !harness.canInstallFromField)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Install from identifier / URL").font(.headline)
        }
    }

    @ViewBuilder
    private func skillsList(harness: SkillsHarness) -> some View {
        // Summary rows only; selecting one opens the `PlatformSplit` detail
        // panel (`SkillDetail`) with the description + kind-appropriate actions.
        List(selection: Binding(
            get: { harness.selectionID },
            set: { harness.selectionID = $0 }
        )) {
            ForEach(harness.rows) { skill in
                SkillRow(
                    skill: skill,
                    kind: harness.kind(for: skill.name),
                    updateAvailable: harness.updatableNames.contains(skill.name),
                    toggling: harness.toggling.contains(skill.name),
                    onToggle: { enabled in Task { await harness.setEnabled(skill.name, enabled: enabled) } }
                )
                .tag(skill.name)
            }
        }
        .overlay {
            if harness.rows.isEmpty, !harness.isLoading {
                ContentUnavailableView("No skills", systemImage: "wand.and.stars")
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func detailPane(harness: SkillsHarness) -> some View {
        if let skill = harness.selected {
            SkillDetail(
                skill: skill,
                kind: harness.kind(for: skill.name),
                isOfficial: harness.isOfficial(skill.name),
                updateAvailable: harness.updatableNames.contains(skill.name),
                mutationsAvailable: mutationsAvailable,
                removeAvailable: removeAvailable,
                lifecycleAvailable: lifecycleAvailable,
                publishAvailable: publishAvailable,
                forceRemoveAvailable: forceRemoveAvailable,
                // Only use the cached resolved dir when it's for *this* skill —
                // loadPreview overwrites it asynchronously, so during a selection
                // change it can still hold the previous skill's path.
                forceRemovePath: (harness.resolvedDirName == skill.name ? harness.resolvedDir : nil)
                    ?? harness.skillDirectoryPath(for: skill),
                busy: harness.busy.contains(skill.name),
                previewText: harness.previewText,
                previewError: harness.previewError,
                previewLoading: harness.previewLoading,
                onUpdate: { Task { await harness.update(skill.name) } },
                onRemove: { Task { await harness.remove(skill.name) } },
                onAudit: { Task { await harness.audit(skill.name) } },
                onReset: { Task { await harness.reset(skill.name) } },
                onRepair: { Task { await harness.repair(skill.name) } },
                onPublish: {
                    Task {
                        let path = await harness.resolvedPublishPath(for: skill)
                        publishTarget = PublishTarget(skillName: skill.name, path: path)
                    }
                },
                onForceRemove: { Task { await harness.forceRemove(skill) } }
            )
        }
    }

}

/// Identifies the local skill being published, seeding the publish sheet.
private struct PublishTarget: Identifiable {
    let skillName: String
    let path: String
    var id: String { skillName }
}

/// One Skills Hub search result row: identity + trust + description, with an
/// Install button (or an "Installed" marker when it's already present).
private struct SkillSearchRow: View {
    let result: HubCatalogSkill
    let installed: Bool
    let installing: Bool
    let canInstall: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    SkillPill(text: result.source, color: .secondary)
                    if !result.trustLevel.isEmpty {
                        SkillPill(text: result.trustLevel, color: trustColor(result.trustLevel))
                    }
                }
                if !result.description.isEmpty {
                    Text(result.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(result.identifier)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Already installed")
            } else if installing {
                ProgressView().controlSize(.small)
            } else {
                Button("Install", action: onInstall)
                    .controlSize(.small)
                    .disabled(!canInstall)
                    .help("Install this skill")
            }
        }
        .padding(.vertical, 6)
    }

    private func trustColor(_ trust: String) -> Color {
        switch trust {
        case "builtin", "trusted", "official": return .green
        case "community": return .orange
        default: return .secondary
        }
    }
}

/// One summary row in the installed-skills list. Name + Hub/Local pill + an
/// update-available hint + category + the enable toggle, over a single-line
/// description preview. Selecting it opens the detail panel (`SkillDetail`),
/// which shows the full, wrapping description; the row itself carries no actions
/// or expansion.
private struct SkillRow: View {
    let skill: DashboardSkill
    let kind: SkillKind?
    let updateAvailable: Bool
    let toggling: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    switch kind {
                    case .hub:
                        SkillPill(text: "Hub", color: .blue)
                    case .local:
                        SkillPill(text: "Local", color: .secondary)
                    case .builtin, .none:
                        EmptyView()
                    }
                    if updateAvailable {
                        Image(systemName: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .help("An update is available from the source")
                            .accessibilityLabel("Update available")
                    }
                }

                Spacer(minLength: 8)

                if let category = skill.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(toggling)
            }

            // One-line preview; the full description lives in the detail panel.
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The detail panel for the selected skill (the `PlatformSplit` secondary):
/// full description plus a kind-appropriate action cluster — hub: Update /
/// Audit / Remove; builtin: Repair (official) / Reset; local: Publish — plus a
/// universal, destructive **Force remove** (local profiles only). Mirrors
/// `PluginDetail`'s prop-drilling style. Per-row confirmations live here.
private struct SkillDetail: View {
    let skill: DashboardSkill
    let kind: SkillKind?
    let isOfficial: Bool
    let updateAvailable: Bool
    let mutationsAvailable: Bool
    let removeAvailable: Bool
    let lifecycleAvailable: Bool
    let publishAvailable: Bool
    let forceRemoveAvailable: Bool
    /// The on-disk directory Force remove deletes, named in its confirmation.
    let forceRemovePath: String
    let busy: Bool
    /// Raw SKILL.md source for the highlighted preview (nil while loading or on
    /// error).
    let previewText: String?
    let previewError: String?
    let previewLoading: Bool
    let onUpdate: () -> Void
    let onRemove: () -> Void
    let onAudit: () -> Void
    let onReset: () -> Void
    let onRepair: () -> Void
    let onPublish: () -> Void
    let onForceRemove: () -> Void

    @State private var confirmingRemove = false
    @State private var confirmingForceRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    switch kind {
                    case .hub:
                        SkillPill(text: "Hub", color: .blue)
                    case .local:
                        SkillPill(text: "Local", color: .secondary)
                    case .builtin:
                        SkillPill(text: "Built-in", color: .secondary)
                    case .none:
                        EmptyView()
                    }
                    if updateAvailable {
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(.blue)
                            .help("An update is available from the source")
                            .accessibilityLabel("Update available")
                    }
                }

                if let category = skill.category, !category.isEmpty {
                    Text(category)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = skill.description, !description.isEmpty {
                    Divider()
                    Text(description)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                actions

                Divider()
                preview
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .alert("Remove \(skill.name)?", isPresented: $confirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This deletes the installed skill from the Hermes host.")
        }
        .alert("Force remove \(skill.name)?", isPresented: $confirmingForceRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Force remove", role: .destructive) { onForceRemove() }
        } message: {
            Text(forceRemoveMessage)
        }
    }

    private var forceRemoveMessage: String {
        let base = "This permanently deletes the skill directory at \(forceRemovePath)."
        // `if case .builtin? =` (not `==`) so SkillKind needn't be Equatable.
        if case .builtin? = kind {
            return base + " A built-in skill may be re-seeded on the next sync unless you opt out of bundled skills."
        }
        return base
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch kind {
                case .hub:
                    hubButtons
                case .builtin:
                    builtinButtons
                case .local:
                    localButtons
                case .none:
                    EmptyView()
                }
                forceRemoveButton
                if busy { ProgressView().controlSize(.small) }
            }
            captions
        }
    }

    /// The skill's `SKILL.md` source, rendered read-only with markdown syntax
    /// highlighting (the same `MarkdownHighlightTheme` the Soul/Memory editors
    /// use). Loading shows a spinner; a missing/unreadable file shows a soft
    /// note. Renders inline so the whole detail panel scrolls for long skills.
    @ViewBuilder
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if previewLoading {
                ProgressView().controlSize(.small)
            } else if let previewText, !previewText.isEmpty {
                Text(Self.highlighted(previewText))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(previewError ?? "Preview unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Highlights the SKILL.md source: the leading `---`-fenced YAML frontmatter
    /// with the YAML theme, the markdown body with the markdown theme. Falls back
    /// to whole-document markdown highlighting when there's no frontmatter.
    private static func highlighted(_ text: String) -> AttributedString {
        guard let parts = MarkdownFrontmatter.split(text) else {
            return AttributedString(MarkdownHighlightTheme.attributed(text))
        }
        let combined = NSMutableAttributedString()
        combined.append(YAMLHighlightTheme.attributed(parts.frontmatter))
        combined.append(MarkdownHighlightTheme.attributed(parts.body))
        return AttributedString(combined)
    }

    /// hub: Update / Audit / Remove.
    @ViewBuilder
    private var hubButtons: some View {
        Button { onUpdate() } label: {
            Label("Update", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(busy || !mutationsAvailable)
        .help("Pull the latest version from the source")

        Button { onAudit() } label: {
            Label("Audit", systemImage: "checkmark.shield")
        }
        .disabled(busy || !lifecycleAvailable)
        .help("Re-scan this skill and show the security report")

        Button(role: .destructive) { confirmingRemove = true } label: {
            Label("Remove", systemImage: "trash")
        }
        .disabled(busy || !removeAvailable)
        .help("Uninstall this skill from the Hermes host")
    }

    /// builtin: Repair (official only) / Reset.
    @ViewBuilder
    private var builtinButtons: some View {
        if isOfficial {
            Button { onRepair() } label: {
                Label("Repair", systemImage: "bandage")
            }
            .disabled(busy || !lifecycleAvailable)
            .help("Backfill this official skill's hub metadata")
        }

        Button { onReset() } label: {
            Label("Reset", systemImage: "arrow.uturn.backward")
        }
        .disabled(busy || !lifecycleAvailable)
        .help("Clear this skill's user-modified tracking")
    }

    /// local: Publish.
    @ViewBuilder
    private var localButtons: some View {
        Button { onPublish() } label: {
            Label("Publish", systemImage: "square.and.arrow.up")
        }
        .disabled(busy || !publishAvailable || !lifecycleAvailable)
        .help("Publish this local skill to a registry")
    }

    /// Universal destructive force-delete of the skill directory. A plain
    /// destructive button that opens a confirmation alert naming the path —
    /// matching the hub clean-uninstall "Remove" flow, so removal is confirmed
    /// the same way regardless of skill kind. The slashed-trash icon and "Force
    /// remove" label keep it distinct from the clean "Remove" button.
    private var forceRemoveButton: some View {
        Button(role: .destructive) {
            confirmingForceRemove = true
        } label: {
            Label("Force remove", systemImage: "trash.slash")
        }
        .disabled(busy || !forceRemoveAvailable)
        .help("Permanently delete this skill's files from disk")
    }

    /// Explanatory captions for unavailable affordances. Uses `if case .X? =`
    /// (not `==`) so SkillKind needn't be Equatable.
    @ViewBuilder
    private var captions: some View {
        if case .hub? = kind, !mutationsAvailable {
            captionText("Admin runner unavailable.")
        } else if case .hub? = kind, !removeAvailable {
            // `hermes skills uninstall` has no `--yes` and prompts on stdin,
            // which only the local runner delivers — so clean Remove is
            // local-only. (Force remove below still works on remote.)
            captionText("Remove is unavailable on remote profiles; use Force remove.")
        }
        if !forceRemoveAvailable {
            captionText("Force remove is unavailable on this profile.")
        }
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Tinted rounded capsule for source / trust / status labels, matching the
/// `PluginPill` styling on the Plugins surface.
private struct SkillPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .lineLimit(1)
    }
}

/// Confirmation sheet for Talaria's local built-in skills resync. The plan is
/// read-only; writes happen only after Confirm calls back into the harness.
private struct BundledSkillsResyncSheet: View {
    let plan: BundledSkillsResyncPlan
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var actionableCount: Int {
        plan.count(.add) + plan.count(.update)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resync built-in skills")
                        .font(.headline)
                    if let commit = plan.sourceCommit {
                        Text("Source commit \(commit.prefix(12))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                Text("\(actionableCount) changes")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(.add, title: "Add", systemImage: "plus.circle")
                    section(.update, title: "Update", systemImage: "arrow.triangle.2.circlepath")
                    section(.skipUnchanged, title: "Up to date", systemImage: "checkmark.circle")
                    section(.skipModified, title: "Skip: locally modified", systemImage: "pencil.circle")
                    section(.skipUnknown, title: "Skip: unknown existing skill", systemImage: "questionmark.circle")
                    section(.skipDeleted, title: "Deleted locally", systemImage: "minus.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280, maxHeight: 520)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Confirm") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(actionableCount == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 620)
    }

    @ViewBuilder
    private func section(_ action: BundledSkillsResyncAction, title: String, systemImage: String) -> some View {
        let rows = plan.items.filter { $0.action == action }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(title) (\(rows.count))", systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(rows) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.caption.weight(.medium))
                                    if let category = item.category, !category.isEmpty {
                                        SkillPill(text: category, color: .secondary)
                                    }
                                }
                                Text(item.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            hashPair(item)
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func hashPair(_ item: BundledSkillsResyncItem) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let currentHash = item.currentHash {
                Text("local \(currentHash.prefix(8))")
            }
            Text("source \(item.sourceHash.prefix(8))")
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
}

/// Sheet for publishing a **local** skill to a registry. Holds the editable
/// registry / repo / path locally and reports the chosen values back through
/// `onPublish`. `path` is seeded from a derived default (publish's positional
/// arg is a directory `skills list` doesn't expose), so it stays editable.
private struct PublishSheet: View {
    let skillName: String
    let onPublish: (String, SkillsPublishRegistry, String?) -> Void

    @State private var path: String
    @State private var registry: SkillsPublishRegistry = .github
    @State private var repo: String = ""
    @Environment(\.dismiss) private var dismiss

    init(
        skillName: String,
        defaultPath: String,
        onPublish: @escaping (String, SkillsPublishRegistry, String?) -> Void
    ) {
        self.skillName = skillName
        self.onPublish = onPublish
        self._path = State(initialValue: defaultPath)
    }

    /// github always needs a repo; clawhub's is optional. The path is always
    /// required (it's publish's positional directory argument).
    private var canPublish: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if registry == .github {
            return !repo.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish “\(skillName)”")
                .font(.headline)

            Form {
                Picker("Registry", selection: $registry) {
                    Text("GitHub").tag(SkillsPublishRegistry.github)
                    Text("ClawHub").tag(SkillsPublishRegistry.clawhub)
                }
                .pickerStyle(.segmented)

                TextField(
                    registry == .github ? "owner/repo" : "owner/repo (optional)",
                    text: $repo
                )

                TextField("Skill directory path", text: $path)
            }
            .formStyle(.grouped)

            if registry == .clawhub {
                Text("ClawHub can infer the repository; leave it blank to use the default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Dismiss without publishing")
                Button("Publish") {
                    let trimmedRepo = repo.trimmingCharacters(in: .whitespaces)
                    onPublish(
                        path.trimmingCharacters(in: .whitespaces),
                        registry,
                        trimmedRepo.isEmpty ? nil : trimmedRepo
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canPublish)
                .help("Publish this skill to the selected registry")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}

/// Sheet presenting a captured `skills audit` report — scrollable, monospaced,
/// with a Done button. Dismissing clears `auditReport` via the `.sheet(item:)`
/// binding.
private struct AuditReportSheet: View {
    let report: SkillAuditReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audit: \(report.name)")
                .font(.headline)

            ScrollView {
                Text(report.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 360)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("Dismiss the audit report")
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}
