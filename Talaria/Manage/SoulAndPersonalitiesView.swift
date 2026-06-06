import HermesKit
import SwiftUI

/// Which row the primary list has selected: the base-soul row (edit `SOUL.md`
/// directly / clear the overlay) or a named personality. A dedicated enum keeps
/// the base-soul row from colliding with a personality that might be named
/// "soul".
enum PersonalitySelection: Hashable {
    case soul
    case personality(String)
}

@MainActor
@Observable
final class PersonalitiesHarness {
    /// Personalities from `agent.personalities`, sorted by name.
    var items: [HermesPersonality] = []
    /// The active overlay (`agent.system_prompt`); empty means no overlay.
    var activePrompt: String = ""
    var selection: PersonalitySelection?
    var isLoading: Bool = false
    var lastError: String?
    /// Names with an in-flight save/delete/activate, so their detail controls
    /// disable while the request is outstanding.
    var busy: Set<String> = []

    /// Single-slot draft for the selected personality's name + prompt. Lifted
    /// here — rather than into the detail view's local `@State` — so the view's
    /// navigation guard can read dirtiness and save from one place, mirroring how
    /// the server editor centralizes its draft in `ProfileEditorState`. Replaced
    /// when the selection changes (the guard prompts before that discard).
    var draftName = ""
    var draftPrompt = ""
    /// The selected personality's persisted values at seed time, so `refresh`
    /// can pick up a server-side change (e.g. normalization after a save) without
    /// clobbering an unrelated in-progress edit (e.g. activating while dirty).
    private var seededName = ""
    private var seededPrompt = ""

    /// Busy key for the base-soul/clear-overlay action, which has no personality
    /// name. NUL can't appear in a YAML mapping key, so it never collides.
    static let noneBusyKey = "\u{0}__none__"

    /// Read fresh on every request rather than captured at construction, so a
    /// supervisor reconnect that swaps the client instance (while it stays
    /// non-nil) doesn't leave the list driving a stale client — matching how the
    /// sibling soul editor reads its client through `defaultClientProvider`.
    private let clientProvider: @MainActor () -> DashboardClient?

    init(client: @escaping @MainActor () -> DashboardClient?) {
        self.clientProvider = client
    }

    var selected: HermesPersonality? {
        guard case let .personality(name) = selection else { return nil }
        return items.first { $0.name == name }
    }

    /// The personality whose resolved prompt matches the active overlay, or nil
    /// when no overlay is set (or none matches — e.g. the overlay was hand-edited
    /// or set by a built-in personality we don't surface). Best-effort, mirroring
    /// how Hermes itself only persists the resolved string.
    var activeName: String? {
        guard !activePrompt.isEmpty else { return nil }
        return items.first { HermesPersonality.resolvedPrompt(for: $0.rawValue) == activePrompt }?.name
    }

    // MARK: - Personality draft

    var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The selected personality's draft diverges from its persisted entry.
    var personalityIsDirty: Bool {
        guard case let .personality(name) = selection,
              let item = items.first(where: { $0.name == name }) else { return false }
        return trimmedDraftName != item.name || draftPrompt != item.prompt
    }

    /// The edited name collides with another personality — saving would destroy
    /// that entry, so it's rejected.
    var personalityNameCollision: Bool {
        guard case let .personality(name) = selection else { return false }
        return trimmedDraftName != name && Set(items.map(\.name)).subtracting([name]).contains(trimmedDraftName)
    }

    var personalityCanSave: Bool {
        guard case let .personality(name) = selection else { return false }
        return !busy.contains(name) && !trimmedDraftName.isEmpty
            && personalityIsDirty && !personalityNameCollision
    }

    /// Selects a row and (re)seeds the draft from the newly-selected personality
    /// (cleared for the base-soul row / no selection). Every selection change —
    /// user taps and post-mutation reselects alike — routes through here so the
    /// draft always tracks the selection.
    func select(_ newSelection: PersonalitySelection?) {
        selection = newSelection
        seedDraft()
    }

    private func seedDraft() {
        if case let .personality(name) = selection,
           let item = items.first(where: { $0.name == name }) {
            draftName = item.name
            draftPrompt = item.prompt
            seededName = item.name
            seededPrompt = item.prompt
        } else {
            draftName = ""
            draftPrompt = ""
            seededName = ""
            seededPrompt = ""
        }
    }

    func refresh() async {
        guard let client = clientProvider() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (items, activePrompt) = HermesPersonality.parse(try await client.getConfig())
            self.items = items
            self.activePrompt = activePrompt
            // Pick up a server-side change to the selected personality's persisted
            // values (e.g. normalization right after a save) without clobbering an
            // unrelated in-progress edit — only reseed the field that changed on disk.
            if case let .personality(name) = selection,
               let item = items.first(where: { $0.name == name }) {
                if item.prompt != seededPrompt { draftPrompt = item.prompt; seededPrompt = item.prompt }
                if item.name != seededName { draftName = item.name; seededName = item.name }
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves a personality's name + prompt. Passing `oldName` (≠ `name`) renames.
    /// On success the saved (possibly renamed) entry is re-selected and the draft
    /// reseeded from it — which also keeps `selection` valid for the navigation
    /// guard's Save, whose stashed `.refresh` won't reselect a row itself.
    func save(name: String, prompt: String, oldName: String?) async {
        // Key the busy marker on the *selected* (old) name — that's what the
        // detail pane checks. On a rename it differs from the new `name`;
        // keying on the new name would leave the detail's controls enabled
        // (no spinner, no disable) during the in-flight write, allowing a
        // duplicate mutation. `oldName ?? name` equals `name` when not renaming.
        await mutate(busyKey: oldName ?? name) {
            HermesPersonality.upsert(name: name, prompt: prompt, into: $0, oldName: oldName)
        }
        // Keep the detail open on the saved (possibly renamed) entry.
        if lastError == nil { select(.personality(name)) }
    }

    func delete(name: String) async {
        await mutate(busyKey: name) { HermesPersonality.remove(name: name, from: $0) }
        if lastError == nil, case .personality(name) = selection { select(nil) }
    }

    /// Activates a personality: writes its resolved prompt to `agent.system_prompt`.
    /// Resolves against the freshly-fetched config so a concurrent edit to the
    /// personality is honoured.
    func activate(name: String) async {
        await mutate(busyKey: name) { fresh in
            let (items, _) = HermesPersonality.parse(fresh)
            guard let item = items.first(where: { $0.name == name }) else { return fresh }
            return HermesPersonality.setActive(
                resolvedPrompt: HermesPersonality.resolvedPrompt(for: item.rawValue),
                in: fresh
            )
        }
    }

    /// Clears the overlay (the base-soul row).
    func clearActive() async {
        await mutate(busyKey: Self.noneBusyKey) { HermesPersonality.setActive(resolvedPrompt: "", in: $0) }
    }

    /// Adds a new (empty, plain-string) personality and selects it for editing.
    func addPersonality() async {
        let name = uniqueName(base: "New Personality")
        await mutate(busyKey: name) { HermesPersonality.upsert(name: name, prompt: "", into: $0) }
        if lastError == nil { select(.personality(name)) }
    }

    /// A name not already taken by an existing personality (`base`, then
    /// `base 2`, `base 3`, …).
    private func uniqueName(base: String) -> String {
        let taken = Set(items.map(\.name))
        if !taken.contains(base) { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Shared GET-fresh → mutate → PUT → refresh cycle. Re-GETs immediately
    /// before the PUT and mutates only the touched subtree (via the pure
    /// `HermesPersonality` helpers), so a concurrent external change to an
    /// unrelated config key is never clobbered.
    private func mutate(busyKey: String, _ transform: @escaping (JSONValue) -> JSONValue) async {
        guard let client = clientProvider() else {
            lastError = "Dashboard is unavailable."
            return
        }
        busy.insert(busyKey)
        defer { busy.remove(busyKey) }
        do {
            let fresh = try await client.getConfig()
            try await client.updateConfig(transform(fresh))
            lastError = nil
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}

/// Integrated editor for the agent's system-prompt stack: the base `SOUL.md`
/// (the no-overlay state) plus the named personality overlays in
/// `agent.personalities`. The base-soul row edits `SOUL.md` directly; selecting
/// it and tapping **Activate** clears the active overlay.
struct SoulAndPersonalitiesView: View {
    let windowHarness: ServerWindowHarness

    /// Live dashboard client; drives the personalities harness. The soul editor
    /// derives its own client from the window harness (and degrades to an
    /// on-disk read when nil), so it can render before this is non-nil.
    private var client: DashboardClient? { windowHarness.dashboardClient }

    @State private var harness: PersonalitiesHarness?
    @State private var soul: SoulEditingState?
    /// A navigation away from the current editor, stashed while the unsaved-edits
    /// confirmation is up. Row selection, Add, and Refresh all route through
    /// `attemptNavigate` so a dirty editor can't be abandoned silently. Mirrors
    /// `DesktopProfileEditor`'s guard — and shares its limit: leaving the whole
    /// view (another sidebar destination) or closing the window isn't
    /// interceptable in SwiftUI, so this protects the common in-view case.
    @State private var pendingNavigation: PendingNavigation?

    private enum PendingNavigation {
        case select(PersonalitySelection?)
        case add
        case refresh
    }

    init(windowHarness: ServerWindowHarness) {
        self.windowHarness = windowHarness
    }

    var body: some View {
        Group {
            if let soul {
                if let harness {
                    content(harness: harness, soul: soul)
                } else {
                    // No live dashboard: the personalities list needs the
                    // dashboard API, but the base SOUL.md still renders from its
                    // own degraded on-disk read — mirroring the old standalone
                    // soul editor, which worked regardless of dashboard state.
                    offlineSoul(soul: soul)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Soul & Personalities")
        // Keyed on client availability: the personalities harness is built when
        // the dashboard comes online and dropped when it goes away (so a defunct
        // client never drives the list). The soul editor is built once and owns
        // its own degraded/on-disk path, so it renders before — and after — the
        // dashboard is reachable.
        .task(id: client != nil) {
            let isFirstBuild = soul == nil
            if isFirstBuild {
                let state = makeSoulState()
                soul = state
                state.load()
            }
            if client != nil {
                if harness == nil {
                    let h = PersonalitiesHarness(client: { [weak windowHarness] in windowHarness?.dashboardClient })
                    harness = h
                    await h.refresh()
                }
            } else {
                // Dashboard went away (or never came online): drop the harness so
                // the view falls back to the offline soul editor instead of
                // rendering the personalities split against a dead client.
                harness = nil
                // Re-read the on-disk SOUL.md degraded, unless we just loaded it
                // or the user has unsaved edits — a mid-edit dashboard drop
                // (e.g. a supervisor reconnect) must never silently clobber the
                // in-progress buffer.
                if !isFirstBuild, soul?.isDirty == false { soul?.load() }
            }
        }
        .onChange(of: windowHarness.dashboardClient != nil) { _, hasClient in
            guard hasClient else { return }
            soul?.reloadIfDashboardAppeared()
        }
        .onDisappear {
            let state = soul
            Task { await state?.teardown() }
        }
    }

    private func makeSoulState() -> SoulEditingState {
        SoulEditingState(
            profileName: windowHarness.hermesProfileName,
            defaultClient: { [weak windowHarness] in windowHarness?.dashboardClient },
            serverProfile: windowHarness.profile,
            transfer: windowHarness.snapshotTransfer
        )
    }

    // Offline / pre-dashboard layout: the base SOUL.md editor alone (degraded
    // read-only via its own on-disk read), with no personalities list since that
    // requires the dashboard API. Flips to the full split as soon as the harness
    // is built.
    @ViewBuilder
    private func offlineSoul(soul: SoulEditingState) -> some View {
        SoulDetail(editor: soul, isActive: nil, busy: false, onActivate: nil)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem {
                    Button { soul.load() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(soul.isLoading)
                    .help("Reload the base SOUL.md from disk")
                }
            }
    }

    @ViewBuilder
    private func content(harness: PersonalitiesHarness, soul: SoulEditingState) -> some View {
        PlatformSplit(
            showsSecondary: Binding(
                get: { harness.selection != nil },
                // Back on iPhone discards any unsaved draft (a pop can't be
                // intercepted) and reseeds cleanly — see the view's dirty-guard note.
                set: { if !$0 { harness.select(nil) } }
            ),
            secondaryTitle: secondaryTitle(harness)
        ) {
            primaryPane(harness: harness, soul: soul)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness, soul: soul)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness, soul: soul) }
        .manageBanner(harness.lastError, severity: .error)
        .confirmationDialog(
            "Unsaved changes",
            isPresented: Binding(
                get: { pendingNavigation != nil },
                set: { if !$0 { pendingNavigation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingNavigation
        ) { action in
            if canSaveCurrent(harness: harness, soul: soul) {
                Button("Save") {
                    saveCurrent(harness: harness, soul: soul, then: action)
                    pendingNavigation = nil
                }
            }
            Button("Discard", role: .destructive) {
                discardCurrent(harness: harness, soul: soul)
                perform(action, harness: harness, soul: soul)
                pendingNavigation = nil
            }
            Button("Cancel", role: .cancel) { pendingNavigation = nil }
        } message: { _ in
            Text("You have unsaved changes to \(currentEditorLabel(harness: harness)).")
        }
    }

    // MARK: - Primary pane

    @ViewBuilder
    private func primaryPane(harness: PersonalitiesHarness, soul: SoulEditingState) -> some View {
        List(selection: Binding(
            get: { harness.selection },
            set: { attemptNavigate(.select($0), harness: harness, soul: soul) }
        )) {
            // Base-soul row — edits SOUL.md directly; active when no overlay is set.
            HStack {
                HStack(spacing: 6) {
                    Text("SOUL.md")
                    Text("base")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if harness.activePrompt.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("Active")
                }
            }
            .tag(PersonalitySelection.soul)
            // A plain iOS List doesn't honor `List(selection:)` taps outside edit
            // mode (so the iPhone push / iPad panel wouldn't open); route the tap
            // through the same dirty-guard the selection binding uses.
            .contentShape(Rectangle())
            .onTapGesture { attemptNavigate(.select(.soul), harness: harness, soul: soul) }

            Section("Personalities") {
                ForEach(harness.items) { item in
                    PersonalityRow(item: item, isActive: harness.activeName == item.name)
                        .tag(PersonalitySelection.personality(item.name))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            attemptNavigate(.select(.personality(item.name)), harness: harness, soul: soul)
                        }
                }
            }
        }
        .overlay {
            if harness.items.isEmpty, !harness.isLoading {
                ContentUnavailableView(
                    "No personalities",
                    systemImage: "theatermasks",
                    description: Text("Add a personality to overlay a system prompt onto the base SOUL.md.")
                )
            }
        }
    }

    /// Title for the pushed iPhone detail page — the base-soul file name or the
    /// selected personality's name. nil when nothing is selected (the pane is hidden).
    private func secondaryTitle(_ harness: PersonalitiesHarness) -> String? {
        switch harness.selection {
        case .soul?: return "SOUL.md"
        case let .personality(name)?: return name
        case nil: return nil
        }
    }

    // MARK: - Detail pane

    // Rendered only when a row is selected — `PlatformSplit`'s `showsSecondary`
    // gate hides this pane entirely otherwise.
    @ViewBuilder
    private func detailPane(harness: PersonalitiesHarness, soul: SoulEditingState) -> some View {
        switch harness.selection {
        case .soul?:
            SoulDetail(
                editor: soul,
                isActive: harness.activePrompt.isEmpty,
                busy: harness.busy.contains(PersonalitiesHarness.noneBusyKey),
                onActivate: { Task { await harness.clearActive() } }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case let .personality(name)?:
            if let item = harness.selected {
                PersonalityDetail(
                    harness: harness,
                    item: item,
                    isActive: harness.activeName == name,
                    busy: harness.busy.contains(name),
                    onActivate: { Task { await harness.activate(name: name) } },
                    onDelete: { Task { await harness.delete(name: name) } }
                )
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(harness: PersonalitiesHarness, soul: SoulEditingState) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                attemptNavigate(.add, harness: harness, soul: soul)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(harness.isLoading)
            .help("Add a personality")

            Button {
                attemptNavigate(.refresh, harness: harness, soul: soul)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading || soul.isLoading)
            .help("Reload the base SOUL.md and personalities")
        }
    }

    // MARK: - Navigation guard

    /// Routes a navigation away from the current editor through the dirty check:
    /// performs it immediately when clean, otherwise raises the confirmation.
    private func attemptNavigate(_ action: PendingNavigation, harness: PersonalitiesHarness, soul: SoulEditingState) {
        if currentDetailIsDirty(harness: harness, soul: soul) {
            pendingNavigation = action
        } else {
            perform(action, harness: harness, soul: soul)
        }
    }

    private func perform(_ action: PendingNavigation, harness: PersonalitiesHarness, soul: SoulEditingState) {
        switch action {
        case let .select(selection):
            harness.select(selection)
        case .add:
            Task { await harness.addPersonality() }
        case .refresh:
            Task { await harness.refresh() }
            soul.load()
        }
    }

    private func currentDetailIsDirty(harness: PersonalitiesHarness, soul: SoulEditingState) -> Bool {
        switch harness.selection {
        case .soul?: return soul.isDirty
        case .personality?: return harness.personalityIsDirty
        case nil: return false
        }
    }

    private func canSaveCurrent(harness: PersonalitiesHarness, soul: SoulEditingState) -> Bool {
        switch harness.selection {
        case .soul?: return soul.canSave
        case .personality?: return harness.personalityCanSave
        case nil: return false
        }
    }

    private func currentEditorLabel(harness: PersonalitiesHarness) -> String {
        switch harness.selection {
        case .soul?: return "the base SOUL.md"
        case .personality?: return "this personality"
        case nil: return "this editor"
        }
    }

    /// Reverts the current editor to its persisted state so "Discard" truly drops
    /// the edits, then the caller `perform`s the stashed navigation.
    private func discardCurrent(harness: PersonalitiesHarness, soul: SoulEditingState) {
        switch harness.selection {
        case .soul?: soul.load()
        // Reseed the draft from the persisted entry. (`refresh` only reseeds a
        // field that changed on disk, so a plain reload wouldn't drop the edits.)
        case let .personality(name)?: harness.select(.personality(name))
        case nil: break
        }
    }

    /// Saves the current editor, then performs the stashed navigation on success.
    /// On failure the navigation is skipped so the user stays put, sees the error,
    /// and keeps their edits.
    private func saveCurrent(harness: PersonalitiesHarness, soul: SoulEditingState, then action: PendingNavigation) {
        switch harness.selection {
        case .soul?:
            Task {
                await soul.save()
                if soul.lastError == nil { perform(action, harness: harness, soul: soul) }
            }
        case let .personality(name)?:
            let newName = harness.trimmedDraftName
            let prompt = harness.draftPrompt
            Task {
                // `save` reselects the saved entry, so `selection` stays valid
                // even when the stashed action is `.refresh` (which doesn't
                // reselect). `.select`/`.add` then override it as usual.
                await harness.save(name: newName, prompt: prompt, oldName: name == newName ? nil : name)
                if harness.lastError == nil { perform(action, harness: harness, soul: soul) }
            }
        case nil:
            perform(action, harness: harness, soul: soul)
        }
    }
}

/// One personality row: name, a one-line prompt preview, and an active checkmark.
private struct PersonalityRow: View {
    let item: HermesPersonality
    let isActive: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.prompt.isEmpty {
                    Text(item.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Active")
            }
        }
    }
}

/// Detail for the base-soul row: edits `SOUL.md` inline (read-only when the
/// dashboard is unavailable) plus an Activate button that clears the overlay so
/// the agent falls back to the base system prompt.
private struct SoulDetail: View {
    let editor: SoulEditingState
    /// Whether the base soul is the active prompt (no overlay). `nil` when the
    /// dashboard is offline and the overlay state is unknown — the active badge
    /// and the Activate (clear-overlay) button are then hidden, since both need
    /// the dashboard.
    let isActive: Bool?
    let busy: Bool
    /// Clears the active personality overlay. `nil` offline (no dashboard to
    /// write to), which hides the Activate button.
    let onActivate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("SOUL.md")
                    .font(.headline)
                Text("base")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isActive == true {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                }
            }
            Text("The base system prompt. Active when no personality overlay is set.")
                .font(.caption)
                .foregroundStyle(.secondary)

            soulTextView

            if let banner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(editor.lastError != nil ? .red : .secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await editor.save() }
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!editor.canSave)
                .help("Save SOUL.md")

                if let onActivate {
                    Button {
                        onActivate()
                    } label: {
                        Label("Activate", systemImage: "checkmark.circle")
                    }
                    .disabled(busy || isActive == true)
                    .help("Clear the active personality overlay")
                }

                if busy || editor.isLoading { ProgressView().controlSize(.small) }
            }

            if onActivate != nil {
                Text("Like Hermes's own /personality command, clearing the overlay applies on the next agent turn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var soulTextView: some View {
        if editor.dashboardUnavailable {
            ScrollView {
                if editor.text.isEmpty {
                    Text("No SOUL.md available.")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                } else {
                    Text(AttributedString(MarkdownHighlightTheme.attributed(editor.text)))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )
        } else {
            HighlightingTextEditor.markdown(text: Binding(
                get: { editor.text },
                set: { editor.text = $0 }
            ))
            .frame(minHeight: 200, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3))
            )
        }
    }

    private var banner: String? {
        if let error = editor.lastError { return error }
        if editor.dashboardUnavailable {
            return "Dashboard unavailable - showing the on-disk SOUL.md read-only. Save is disabled."
        }
        return nil
    }
}

/// Editable detail for one personality: name, prompt, and Activate/Save/Delete.
/// The name/prompt draft lives in the harness (`draftName`/`draftPrompt`) so the
/// view's navigation guard shares one source of dirty/save truth; this view binds
/// to it. Seeding/reseeding happens in `PersonalitiesHarness.select`.
private struct PersonalityDetail: View {
    @Bindable var harness: PersonalitiesHarness
    let item: HermesPersonality
    let isActive: Bool
    let busy: Bool
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var confirmingActivate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Name", text: $harness.draftName)
                    .font(.headline)
                    .textFieldStyle(.plain)
                if isActive {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                }
            }

            if harness.personalityNameCollision {
                Text("A personality named “\(harness.trimmedDraftName)” already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HighlightingTextEditor.markdown(text: $harness.draftPrompt)
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    let newName = harness.trimmedDraftName
                    Task {
                        await harness.save(
                            name: newName,
                            prompt: harness.draftPrompt,
                            oldName: item.name == newName ? nil : item.name
                        )
                    }
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!harness.personalityCanSave)
                .help("Save this personality")

                Button {
                    // Activate resolves the *persisted* prompt; with unsaved
                    // edits that's not what the editor shows, so confirm first.
                    if harness.personalityIsDirty { confirmingActivate = true } else { onActivate() }
                } label: {
                    Label("Activate", systemImage: "theatermasks")
                }
                .disabled(busy || isActive)
                .help("Make this the active personality overlay")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(busy)
                .help("Delete this personality")

                if busy { ProgressView().controlSize(.small) }
            }

            Text("Activate persists agent.system_prompt and, like Hermes's /personality command, applies on the next agent turn.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .alert("Delete \(item.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the personality from agent.personalities. If it's the active overlay, the overlay is cleared too.")
        }
        .confirmationDialog(
            "Activate with unsaved changes?",
            isPresented: $confirmingActivate,
            titleVisibility: .visible
        ) {
            // Only offer Save & Activate when the draft is actually saveable
            // (a name collision or empty name blocks it).
            if harness.personalityCanSave {
                Button("Save & Activate") {
                    let newName = harness.trimmedDraftName
                    let oldName = item.name
                    Task {
                        await harness.save(name: newName, prompt: harness.draftPrompt, oldName: oldName == newName ? nil : oldName)
                        if harness.lastError == nil { await harness.activate(name: newName) }
                    }
                }
            }
            Button("Activate anyway") { onActivate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This personality has unsaved edits. Activating uses the saved prompt, not your current edits.")
        }
    }
}
