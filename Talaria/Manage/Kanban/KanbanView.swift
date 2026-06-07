import HermesKit
import SwiftUI

/// Kanban Browse destination — a column board backed by the Hermes dashboard
/// kanban plugin (`/api/plugins/kanban`). Mirrors the Cron/Profiles surfaces:
/// builds its harness once the dashboard `client` is ready, lays out a
/// `PlatformSplit`, and surfaces errors / gating through `.manageBanner`.
struct KanbanView: View {
    let client: DashboardClient?
    let hermesVersion: HermesVersion?

    @Environment(BannerCenter.self) private var banners: BannerCenter?
    /// Window navigator: a kanban-board `EntityLink` switches to that board when
    /// this page lands. Optional so the view renders without one.
    @Environment(WindowNavigator.self) private var navigator: WindowNavigator?

    @State private var harness: KanbanHarness?
    @State private var showManageSheet = false

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    /// Restarts the polling loop whenever the dashboard becomes ready or the
    /// board / archived filter changes — SwiftUI cancels the old `.task` and
    /// starts a fresh one, so no manual stop is needed.
    private struct PollKey: Equatable {
        let ready: Bool
        let slug: String?
        let archived: Bool
    }

    private var pollKey: PollKey {
        PollKey(
            ready: harness != nil,
            slug: harness?.selectedBoardSlug,
            archived: harness?.includeArchived ?? false
        )
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Kanban")
        .dismissesBanner("kanban", from: banners)
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness == nil {
                let h = KanbanHarness(client: client)
                h.banners = banners
                harness = h
            }
            if let harness { consumeFocus(harness: harness) }
        }
        .onAppear { if let harness { consumeFocus(harness: harness) } }
        .onChange(of: navigator?.pendingFocus) { _, _ in
            if let harness { consumeFocus(harness: harness) }
        }
        // Polling lives here, not in the harness: SwiftUI auto-cancels on
        // disappear and restarts on board/filter change. ~4s cadence, no
        // WebSocket in v1.
        .task(id: pollKey) {
            guard let harness else { return }
            // The first load after any (re)start — startup, board switch, or
            // archived toggle — is user-visible (`isPoll: false`): it surfaces a
            // failure (otherwise a non-404 first-load error leaves a blank board
            // with no banner) and shows the loading state. Every later background
            // tick is silent, so a mutation's error/warning survives until the
            // user's next action (see `refresh`).
            var loud = true
            while !Task.isCancelled {
                await harness.refresh(isPoll: !loud)
                loud = false
                // Back off hard once the plugin is known-missing: a 404 keeps
                // `pluginUnavailable` set, so re-probe every 60s instead of
                // hammering the absent `/board` route every 4s. A quiet probe
                // still auto-recovers (clears the flag, restoring the 4s cadence)
                // if the plugin is installed later.
                try? await Task.sleep(for: harness.pluginUnavailable ? .seconds(60) : .seconds(4))
            }
        }
    }

    /// Switches to the board named by a pending kanban focus, then clears it.
    /// Ignores focus aimed at another page.
    private func consumeFocus(harness: KanbanHarness) {
        guard let ref = navigator?.pendingFocus, case let .kanbanBoard(slug) = ref else { return }
        if harness.selectedBoardSlug != slug {
            Task { await harness.switchBoard(slug: slug) }
        }
        Task { @MainActor in navigator?.pendingFocus = nil }
    }

    @ViewBuilder
    private func content(harness: KanbanHarness) -> some View {
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.showsSecondary },
                set: { if !$0 { harness.closeSecondary() } }
            ),
            secondaryTitle: secondaryTitle(harness)
        ) {
            KanbanBoardColumnsView(harness: harness)
                .frame(minWidth: Idiom.isPhone ? nil : 420, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            secondaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        .manageBanner(bannerMessage(harness), severity: bannerSeverity(harness))
        .sheet(isPresented: $showManageSheet) {
            KanbanBoardManageSheet(harness: harness)
        }
    }

    /// Title for the pushed iPhone secondary page — "New Task" for the create
    /// draft, or the selected card's title. nil when neither opens it.
    private func secondaryTitle(_ harness: KanbanHarness) -> String? {
        if harness.draft != nil { return "New Task" }
        return harness.selectedCard?.title
    }

    @ViewBuilder
    private func secondaryPane(harness: KanbanHarness) -> some View {
        if harness.draft != nil {
            KanbanTaskCreatePane(
                draft: Binding(
                    get: { harness.draft ?? KanbanDraft() },
                    set: { harness.draft = $0 }
                ),
                assignees: harness.board?.assignees ?? [],
                onSave: { draft in Task { await harness.createTask(draft) } },
                onCancel: { harness.cancelCreate() }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let card = harness.selectedCard {
            KanbanTaskDetailPane(harness: harness, card: card)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @ToolbarContentBuilder
    private func toolbar(harness: KanbanHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            KanbanBoardMenu(harness: harness, showManageSheet: $showManageSheet)
            Button { Task { await harness.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Refresh the board")
            Button { harness.beginCreate() } label: {
                Label("New Task", systemImage: "plus")
            }
            .disabled(harness.draft != nil || harness.pluginUnavailable)
            .help("Create a new task")
            Toggle(isOn: Binding(
                get: { harness.includeArchived },
                set: { harness.includeArchived = $0 }
            )) {
                Label("Archived", systemImage: "archivebox")
            }
            .help("Show archived tasks")
        }
    }

    // MARK: - Banner

    // Hard errors (`lastError`) route to the top-of-window strip. The in-surface
    // banner keeps the orange notices: an informational success warning, then
    // plugin-unavailable, then the version-capability notice — all `.warning`.
    private func bannerMessage(_ harness: KanbanHarness) -> String? {
        if let warning = harness.lastWarning { return warning }
        if harness.pluginUnavailable { return "Kanban plugin not available on this server." }
        return capabilityBanner(
            .requiresDashboard,
            feature: "Kanban via Hermes dashboard",
            version: hermesVersion
        )
    }

    private func bannerSeverity(_ harness: KanbanHarness) -> ManageBanner.Severity {
        .warning
    }
}
