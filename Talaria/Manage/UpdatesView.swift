import HermesKit
import SwiftUI

/// Process-wide registry of which profiles currently have a `hermes update`
/// apply in flight. The per-window ``UpdatesHarness`` `isApplying`/`isChecking`
/// guards only cover a single window; multiple windows can be open on one
/// profile (they share a dashboard — and one source-install repo). This scopes
/// the **apply-vs-automatic-check** interlock to the shared repo so one window's
/// background timer doesn't fire `hermes update --check` (a `git fetch`) against
/// another window's in-progress `hermes update` (a `git pull`/checkout). A
/// refcount, not a flag, so two overlapping applies on the same profile don't
/// clear each other early.
@MainActor
final class UpdateApplyCoordinator {
    static let shared = UpdateApplyCoordinator()
    private var applyCounts: [UUID: Int] = [:]
    private init() {}

    func setApplying(_ on: Bool, profileId: UUID) {
        let next = max(0, (applyCounts[profileId] ?? 0) + (on ? 1 : -1))
        applyCounts[profileId] = next == 0 ? nil : next
    }

    func isApplying(profileId: UUID) -> Bool {
        (applyCounts[profileId] ?? 0) > 0
    }
}

@MainActor
@Observable
final class UpdatesHarness {
    struct LogEntry: Identifiable, Equatable {
        let id: Int
        let text: String
    }

    var status: UpdateStatus?
    var isChecking: Bool = false
    var isApplying: Bool = false
    var applyLog: [LogEntry] = []
    var applyExitCode: Int32?
    var lastError: String?
    /// Top-of-window banner hub (window-scoped). Hard errors route here keyed by
    /// the surface id so they render full-width across the top. Optional so a
    /// missing host degrades to no-op.
    var banners: BannerCenter?

    /// Invoked when a background check finds an update has *newly* become
    /// available (de-duped — see ``backgroundCheck()``). The host wires this to
    /// ``ChatNotifier`` so the surfacing is an OS notification. `nil` (and the
    /// loop inert) until wired, keeping the harness unit-testable in isolation.
    var onUpdateAvailable: ((UpdateStatus) -> Void)?

    /// Invoked when a background check finds the server is up to date. The host
    /// wires this to clear ``ChatNotifier``'s cross-window update-notification
    /// de-dupe, so a later update notifies again even though this window's own
    /// notification already fired earlier.
    var onUpdateCleared: (() -> Void)?

    /// Snapshot of the background-check preferences, read once per loop tick so
    /// the harness never references the settings store directly. Defaults to
    /// disabled, so the mock/test path runs no background checks unless wired.
    var settingsSnapshot: () -> (enabled: Bool, interval: Duration) = { (false, .seconds(86_400)) }

    /// True when *any* window on this profile has an apply in flight. A
    /// background check consults it so it skips the tick rather than racing a
    /// `git fetch` against another window's in-progress `hermes update` on the
    /// same source-install repo. Defaults to `false` (inert) so the harness stays
    /// decoupled/testable; the host wires it to ``UpdateApplyCoordinator``.
    var isProfileApplying: () -> Bool = { false }

    /// Marks this profile's apply in-flight state in the process-wide
    /// ``UpdateApplyCoordinator`` so other windows' background checks see it.
    /// Defaults to a no-op (inert in tests/mock).
    var markApplying: (Bool) -> Void = { _ in }

    let runner: HermesAdminRunning?

    private var nextLogID: Int = 0
    private var applyTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    /// De-dupe state so the same un-applied update doesn't re-notify every
    /// interval. Semver builds key on `latest` (a newer release re-notifies);
    /// source-install builds have no version — their `detail` carries a drifting
    /// commits-behind count — so they instead notify once per availability
    /// streak via `notifiedSourceAvailable`. Both reset when the check reports
    /// "up to date" (e.g. after the user applies), so a later update notifies
    /// again.
    private var lastNotifiedLatest: HermesVersion?
    private var notifiedSourceAvailable: Bool = false

    init(runner: HermesAdminRunning?) {
        self.runner = runner
    }

    private func appendLog(_ text: String) {
        applyLog.append(LogEntry(id: nextLogID, text: text))
        nextLogID += 1
        if applyLog.count > 5000 {
            applyLog.removeFirst(applyLog.count - 5000)
        }
    }

    /// Manual check (the Check button + the post-apply refresh). Surfaces errors
    /// to `lastError`/the banner, unlike the silent background path.
    ///
    /// Guards on `!isChecking` so it can't run concurrently with an in-flight
    /// check (background or manual): the view's `.task` fires this on appear when
    /// `status == nil`, which can land while the background loop's first check is
    /// still running (status not yet assigned) and otherwise race a second
    /// `hermes update --check` on the same source-install repo. Not gated on
    /// `isApplying` — the post-apply refresh runs while `isApplying` is still set
    /// (but `isChecking` is clear), and must proceed.
    func check() async {
        guard !isChecking else { return }
        await performCheck(silent: false)
    }

    /// The unit-testable background path. Skips this tick (rather than queueing)
    /// if another update operation is in flight — the next interval catches up —
    /// and is **silent** on failure (no `lastError`, no banner). When an update
    /// is newly available it invokes ``onUpdateAvailable`` exactly once per
    /// distinct update, recording it so the same update doesn't re-notify.
    func backgroundCheck() async {
        guard runner != nil else { return }
        // Skip if this window is busy, or if another window on the same profile is
        // mid-apply (the cross-window check-vs-apply interlock).
        guard !isChecking, !isApplying, !isProfileApplying() else { return }
        await performCheck(silent: true)
        // The up-to-date reset lives in `performCheck` so every path (manual,
        // background, post-apply refresh) clears the de-dupe; here we only handle
        // the newly-available → notify case.
        guard let status, status.available else { return }
        if let latest = status.latest {
            // Semver: the version is the key, so a newer release re-notifies.
            guard latest != lastNotifiedLatest else { return }
            lastNotifiedLatest = latest
        } else {
            // Source-install build: no version to key on, and the commits-behind
            // count in `detail` drifts as upstream advances — so notify once per
            // availability streak rather than every interval for the same update.
            guard !notifiedSourceAvailable else { return }
            notifiedSourceAvailable = true
        }
        onUpdateAvailable?(status)
    }

    /// Shared core for manual and background checks: claims the `isChecking`
    /// gate (so it blocks, and is blocked by, the other operations), runs
    /// `hermes update --check`, assigns `status`, and appends a concise result
    /// line to the **same** `applyLog` the manual/apply flow shows — there is one
    /// update-activity log, not a hidden background path. `silent` swallows
    /// errors (background is best-effort).
    private func performCheck(silent: Bool) async {
        guard let runner else { return }
        isChecking = true
        defer { isChecking = false }
        if !silent { lastError = nil }
        do {
            let result = try await HermesUpdates.check(runner: runner)
            status = result
            banners?.dismiss(key: "updates")
            appendLog(checkResultLine(result))
            if !result.available {
                // Whenever *any* path observes "up to date" — a manual check, a
                // background tick, or the post-apply refresh — reset the de-dupe
                // so a later update notifies again, and clear the cross-window
                // token. Doing this here (not only in `backgroundCheck`) means an
                // apply doesn't leave a source-install update suppressed until the
                // next background tick.
                resetNotificationDedup()
            }
        } catch {
            if silent {
                appendLog("Update check failed")
            } else {
                lastError = error.localizedDescription
                banners?.surfaceError("updates", error.localizedDescription)
            }
        }
    }

    /// Clears the per-window de-dupe state and the cross-window notification
    /// token so a subsequent update notifies again.
    private func resetNotificationDedup() {
        lastNotifiedLatest = nil
        notifiedSourceAvailable = false
        onUpdateCleared?()
    }

    private func checkResultLine(_ status: UpdateStatus) -> String {
        if status.available {
            if let current = status.current, let latest = status.latest {
                return "↑ Update available: \(Self.formatVersion(current)) → \(Self.formatVersion(latest))"
            }
            if let detail = status.detail, !detail.isEmpty {
                return "↑ Update available: \(detail)"
            }
            return "↑ Update available"
        }
        if let current = status.current {
            return "✓ Up to date (\(Self.formatVersion(current)))"
        }
        return "✓ Up to date"
    }

    static func formatVersion(_ v: HermesVersion) -> String {
        var s = "\(v.major).\(v.minor).\(v.patch)"
        if let pre = v.prerelease { s += "-\(pre)" }
        return s
    }

    /// Starts (or restarts) the background loop. Each tick reads the settings
    /// snapshot and, if enabled, runs one ``backgroundCheck()`` then sleeps for
    /// the configured interval; if disabled the loop exits and ``observeSettings``
    /// restarts it when the user re-enables. Restarting runs an immediate first
    /// check.
    func startBackgroundChecks() {
        guard runner != nil else { return }
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.settingsSnapshot()
                guard snapshot.enabled else { return }
                await self.backgroundCheck()
                try? await Task.sleep(for: snapshot.interval)
            }
        }
    }

    func stopBackgroundChecks() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    /// Re-runs the background loop whenever the toggle/interval changes, using
    /// the Observation re-arm pattern. Reading `settingsSnapshot()` inside the
    /// tracking closure registers the underlying `@Observable` settings reads, so
    /// a flip restarts the loop (enable → immediate check; disable → loop exits
    /// promptly). `onChange` fires once, so we re-arm each time.
    func observeSettings() {
        withObservationTracking {
            _ = settingsSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startBackgroundChecks()
                self.observeSettings()
            }
        }
    }

    func apply() {
        guard let runner, !isApplying, !isChecking else { return }
        isApplying = true
        // Publish the apply to the process-wide coordinator so another window's
        // background check on the same source-install repo skips while we run.
        markApplying(true)
        applyLog.removeAll()
        applyExitCode = nil
        lastError = nil
        banners?.dismiss(key: "updates")
        let stream = HermesUpdates.apply(runner: runner)
        applyTask = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.isApplying = false
                    self?.markApplying(false)
                }
            }
            do {
                var exit: Int32?
                for try await event in stream {
                    guard let self else { return }
                    switch event {
                    case .stdoutLine(let line), .stderrLine(let line):
                        self.appendLog(line)
                    case .exit(let code):
                        self.applyExitCode = code
                        exit = code
                    }
                }
                // Refresh the status banner once the update applies cleanly
                // so the "Install update" button disables itself and the
                // "X commits behind"/version subtitle reflects post-update
                // reality. On non-zero exits the previous status is still
                // accurate, so leave it alone.
                if exit == 0 {
                    await self?.check()
                }
            } catch is CancellationError {
                // User tapped Cancel — normal exit path, no banner.
                return
            } catch {
                self?.lastError = error.localizedDescription
                self?.banners?.surfaceError("updates", error.localizedDescription)
            }
        }
    }

    func cancelApply() {
        applyTask?.cancel()
        applyTask = nil
    }
}

struct UpdatesView: View {
    let updates: UpdatesHarness?
    let hermesVersion: HermesVersion?

    /// Window's top-of-window banner hub. Optional so a host that doesn't supply
    /// one degrades to no-op (hard errors then simply don't render).
    @Environment(BannerCenter.self) private var banners: BannerCenter?

    init(updates: UpdatesHarness?, hermesVersion: HermesVersion? = nil) {
        self.updates = updates
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if let updates, updates.runner != nil {
                content(harness: updates)
            } else {
                // No shell/admin runner (e.g. a dashboard-only or mock
                // profile): `hermes update --check` is a CLI path, so there's
                // nothing to ask. Surface that rather than a false verdict.
                CLIUnavailableView(
                    title: "Admin runner unavailable",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: "Open a server with a Hermes binary to check for updates."
                )
            }
        }
        .navigationTitle("Updates")
        .dismissesBanner("updates", from: banners)
        // Wire the window banner hub into the window-owned harness on every
        // appear (the `.task` below may early-return, so it can't own this).
        .onAppear { updates?.banners = banners }
        // Kick off the first check once the harness is available. `status ==
        // nil` guards against clobbering an in-flight apply when the user
        // navigates back mid-apply — the apply log persists.
        .task(id: updates != nil) {
            guard let updates, updates.runner != nil, updates.status == nil else { return }
            await updates.check()
        }
    }

    @ViewBuilder
    private func content(harness: UpdatesHarness) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBanner(harness: harness)
            HStack(spacing: 8) {
                Button {
                    Task { await harness.check() }
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                // Also block while an apply runs: `check()` spawns `hermes
                // update --check` (a git fetch) which would race the in-flight
                // `hermes update` on the same source-install repo and could
                // clobber status/lastError mid-apply.
                .disabled(harness.isChecking || harness.isApplying)

                Button {
                    harness.apply()
                } label: {
                    Label("Install update", systemImage: "arrow.down.circle.fill")
                }
                // Also block while a check runs (manual or background): an apply
                // must not start mid-check on the same source-install repo.
                .disabled(
                    harness.isApplying
                    || harness.isChecking
                    || harness.status?.available != true
                )

                if harness.isApplying {
                    Button("Cancel") { harness.cancelApply() }
                }

                if harness.isChecking || harness.isApplying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let code = harness.applyExitCode {
                    Text("Apply exited \(code)")
                        .font(.caption)
                        .foregroundStyle(code == 0 ? .green : .red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            applyLogView(harness: harness)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Hard errors now route to the top-of-window strip; only the orange
        // capability warning stays in-surface.
        .manageBanner(
            capabilityBanner(
                .updateCheck,
                feature: "`hermes update --check`",
                version: hermesVersion
            ),
            severity: .warning
        )
    }

    @ViewBuilder
    private func statusBanner(harness: UpdatesHarness) -> some View {
        if let status = harness.status {
            HStack(spacing: 8) {
                Image(systemName: status.available ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(status.available ? Color.accentColor : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.available ? "Update available" : "Up to date")
                        .font(.headline)
                    if let subtitle = subtitle(for: status) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((status.available ? Color.accentColor : Color.green).opacity(0.12))
        }
    }

    /// Prefer the semver delta when both versions are known; otherwise
    /// surface the human-readable detail string (e.g. "122 commits behind
    /// origin/main") that the source-install update notice provides.
    private func subtitle(for status: UpdateStatus) -> String? {
        if status.available, let current = status.current, let latest = status.latest {
            return "\(formatVersion(current)) → \(formatVersion(latest))"
        }
        if let current = status.current, !status.available {
            return "Current \(formatVersion(current))"
        }
        return status.detail
    }

    @ViewBuilder
    private func applyLogView(harness: UpdatesHarness) -> some View {
        if harness.applyLog.isEmpty {
            ContentUnavailableView("Update log", systemImage: "text.viewfinder", description: Text("Output appears here once an update is applied."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(harness.applyLog) { entry in
                            Text(entry.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: harness.applyLog.last?.id) { _, newValue in
                    if let newValue {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formatVersion(_ v: HermesVersion) -> String {
        UpdatesHarness.formatVersion(v)
    }
}
