import HermesKit
import SwiftUI

/// Which row the primary list has selected: the synthetic "None" row (clear the
/// overlay) or a named personality. A dedicated enum keeps the "None" row from
/// colliding with a personality that might be named "none".
enum PersonalitySelection: Hashable {
    case none
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

    /// Busy key for the "None"/clear-overlay action, which has no personality
    /// name. NUL can't appear in a YAML mapping key, so it never collides.
    static let noneBusyKey = "\u{0}__none__"

    private let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
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

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let (items, activePrompt) = HermesPersonality.parse(try await client.getConfig())
            self.items = items
            self.activePrompt = activePrompt
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Saves a personality's name + prompt. Passing `oldName` (≠ `name`) renames.
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
        if lastError == nil { selection = .personality(name) }
    }

    func delete(name: String) async {
        await mutate(busyKey: name) { HermesPersonality.remove(name: name, from: $0) }
        if lastError == nil, case .personality(name) = selection { selection = nil }
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

    /// Clears the overlay (the "None" row).
    func clearActive() async {
        await mutate(busyKey: Self.noneBusyKey) { HermesPersonality.setActive(resolvedPrompt: "", in: $0) }
    }

    /// Adds a new (empty, plain-string) personality and selects it for editing.
    func addPersonality() async {
        let name = uniqueName(base: "New Personality")
        await mutate(busyKey: name) { HermesPersonality.upsert(name: name, prompt: "", into: $0) }
        if lastError == nil { selection = .personality(name) }
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

struct PersonalitiesView: View {
    let client: DashboardClient?
    /// Plumbed through for consistency with sibling Manage screens. There is no
    /// version gate: personalities + `/api/config` exist on all supported Hermes
    /// versions.
    let hermesVersion: HermesVersion?

    @State private var harness: PersonalitiesHarness?

    init(client: DashboardClient?, hermesVersion: HermesVersion? = nil) {
        self.client = client
        self.hermesVersion = hermesVersion
    }

    var body: some View {
        Group {
            if client == nil {
                ContentUnavailableView(
                    "Dashboard not ready",
                    systemImage: "theatermasks",
                    description: Text("Waiting for the Hermes dashboard to come online.")
                )
            } else if let harness {
                content(harness: harness)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Personalities")
        // Keyed on client availability so the harness is built when the
        // dashboard finishes booting and `client` flips non-nil (matching the
        // other dashboard surfaces).
        .task(id: client != nil) {
            guard let client else { harness = nil; return }
            if harness != nil { return }
            let h = PersonalitiesHarness(client: client)
            harness = h
            await h.refresh()
        }
    }

    @ViewBuilder
    private func content(harness: PersonalitiesHarness) -> some View {
        PlatformSplit(showsSecondary: harness.selection != nil) {
            primaryPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(harness: harness)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(harness: harness) }
        .manageBanner(harness.lastError, severity: .error)
    }

    // MARK: - Primary pane

    @ViewBuilder
    private func primaryPane(harness: PersonalitiesHarness) -> some View {
        List(selection: Binding(
            get: { harness.selection },
            set: { harness.selection = $0 }
        )) {
            // "None" overlay row — active when no system_prompt is set.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("None")
                    Text("Base SOUL.md — no overlay")
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
            .tag(PersonalitySelection.none)

            Section("Personalities") {
                ForEach(harness.items) { item in
                    PersonalityRow(item: item, isActive: harness.activeName == item.name)
                        .tag(PersonalitySelection.personality(item.name))
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

    // MARK: - Detail pane

    // Rendered only when a row is selected — `PlatformSplit`'s `showsSecondary`
    // gate hides this pane entirely otherwise.
    @ViewBuilder
    private func detailPane(harness: PersonalitiesHarness) -> some View {
        switch harness.selection {
        case .none?:
            NonePersonalityDetail(
                isActive: harness.activePrompt.isEmpty,
                busy: harness.busy.contains(PersonalitiesHarness.noneBusyKey),
                onActivate: { Task { await harness.clearActive() } }
            )
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case let .personality(name)?:
            if let item = harness.selected {
                PersonalityDetail(
                    item: item,
                    // Other personalities' names, so the detail can reject a
                    // rename that would overwrite an existing entry.
                    otherNames: Set(harness.items.map(\.name)).subtracting([name]),
                    isActive: harness.activeName == name,
                    busy: harness.busy.contains(name),
                    onSave: { newName, prompt in
                        Task { await harness.save(name: newName, prompt: prompt, oldName: name == newName ? nil : name) }
                    },
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
    private func toolbar(harness: PersonalitiesHarness) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await harness.addPersonality() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(harness.isLoading)
            .help("Add a personality")

            Button {
                Task { await harness.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(harness.isLoading)
            .help("Reload the personalities")
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

/// Detail for the synthetic "None" row: explains the cleared state and offers an
/// Activate button that clears the overlay.
private struct NonePersonalityDetail: View {
    let isActive: Bool
    let busy: Bool
    let onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("None")
                    .font(.headline)
                if isActive {
                    Text("Active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                }
            }
            Text("No personality overlay — the agent uses the base SOUL.md behavior.")
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 8) {
                Button {
                    onActivate()
                } label: {
                    Label("Activate", systemImage: "checkmark.circle")
                }
                .disabled(busy || isActive)
                .help("Clear the active personality overlay")
                if busy { ProgressView().controlSize(.small) }
            }

            Text("Like Hermes's own /personality command, this applies on the next agent turn.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

/// Editable detail for one personality: name, prompt, and Activate/Save/Delete.
private struct PersonalityDetail: View {
    let item: HermesPersonality
    /// Names of the *other* personalities, used to block a rename that would
    /// silently overwrite an existing entry.
    let otherNames: Set<String>
    let isActive: Bool
    let busy: Bool
    let onSave: (_ name: String, _ prompt: String) -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var draftName: String = ""
    @State private var draftPrompt: String = ""
    @State private var confirmingDelete = false

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The edited name collides with another personality — saving would destroy
    /// that entry, so it's rejected.
    private var nameCollision: Bool {
        trimmedName != item.name && otherNames.contains(trimmedName)
    }

    private var isDirty: Bool {
        trimmedName != item.name || draftPrompt != item.prompt
    }

    private var canSave: Bool {
        !busy && !trimmedName.isEmpty && isDirty && !nameCollision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Name", text: $draftName)
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

            if nameCollision {
                Text("A personality named “\(trimmedName)” already exists.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $draftPrompt)
                    .font(.body)
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    onSave(trimmedName, draftPrompt)
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSave)
                .help("Save this personality")

                Button {
                    onActivate()
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
        // Reset drafts whenever the selected personality changes — the same view
        // is reused across selections, so seed from the new item explicitly.
        .id(item.name)
        .onChange(of: item.name, initial: true) { _, _ in
            draftName = item.name
            draftPrompt = item.prompt
        }
        // After a save reloads the item, pick up any server-side normalization
        // so the dirty check reflects the persisted value.
        .onChange(of: item.prompt) { _, newValue in draftPrompt = newValue }
        .alert("Delete \(item.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This removes the personality from agent.personalities. If it's the active overlay, the overlay is cleared too.")
        }
    }
}
