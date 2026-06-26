import HermesKit
import SwiftUI

/// Read-only browser for the **Hindsight** memory provider. Lists stored memory
/// units (newest-first, paginated) and switches to semantic search via the
/// provider's `recall` endpoint. Talks directly to the Hindsight REST API
/// (localhost for the embedded daemon; cloud / local_external otherwise) — Hermes
/// exposes no dashboard route for browsing Hindsight's vector store.
///
/// Pure SwiftUI (no platform APIs), so it lives in the shared tree and compiles
/// for both targets. The data/transport logic is in HermesKit (tested); this
/// view model is thin orchestration, mirroring ``MemoryHarness``.
@MainActor
@Observable
final class HindsightBrowserModel {
    enum Phase: Equatable { case idle, loading, loaded, empty }
    private enum Mode { case list, search }

    var phase: Phase = .idle
    var browseError: HindsightBrowseError?
    var memories: [HindsightMemory] = []
    var selection: HindsightMemory.ID?
    var searchText = ""
    var total = 0
    var isLoadingMore = false

    private var client: HindsightAPIClient?
    private var bankID: String?
    private var teardown: (@Sendable () async -> Void)?
    private var offset = 0
    private let pageSize = 50
    private var mode: Mode = .list

    private let profile: ServerProfile
    private let profileName: String
    private let transfer: RemoteSnapshotTransfer?
    /// Supplies a transport to a remote profile's Hindsight daemon (macOS `ssh -L`
    /// forward / iOS NIO `direct-tcpip`). Nil for local profiles, which dial the
    /// daemon directly.
    private let remoteTransport: (any HindsightRemoteTransport)?

    init(
        profile: ServerProfile,
        profileName: String,
        transfer: RemoteSnapshotTransfer?,
        remoteTransport: (any HindsightRemoteTransport)? = nil
    ) {
        self.profile = profile
        self.profileName = profileName
        self.transfer = transfer
        self.remoteTransport = remoteTransport
    }

    var selected: HindsightMemory? { memories.first { $0.id == selection } }
    var canLoadMore: Bool { mode == .list && memories.count < total && phase == .loaded }

    /// Resolve the client (once) and load the first page, newest-first.
    func load() async {
        phase = .loading
        browseError = nil
        do {
            let (client, bank) = try await resolvedClient()
            mode = .list
            offset = 0
            let page = try await client.listMemories(bank: bank, limit: pageSize, offset: 0)
            memories = page.items
            total = page.total
            offset = page.items.count
            phase = memories.isEmpty ? .empty : .loaded
        } catch {
            fail(error)
        }
    }

    /// Append the next page of list results (infinite scroll / "Load more").
    func loadMore() async {
        guard canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            // Re-resolve like load()/runSearch(): the tunnel/client may have been
            // torn down while the tab was off-screen (a TabView fires .onDisappear
            // on inner-tab switches), and the .task won't reload an existing model.
            let (client, bank) = try await resolvedClient()
            let page = try await client.listMemories(bank: bank, limit: pageSize, offset: offset)
            memories.append(contentsOf: page.items)
            total = page.total
            offset += page.items.count
        } catch {
            fail(error)
        }
    }

    /// Run a semantic search via `recall`. Empty query reverts to the list.
    func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await load()
            return
        }
        phase = .loading
        browseError = nil
        do {
            let (client, bank) = try await resolvedClient()
            mode = .search
            let results = try await client.recall(bank: bank, query: query)
            memories = results
            total = results.count
            phase = results.isEmpty ? .empty : .loaded
        } catch {
            fail(error)
        }
    }

    func clearSearch() async {
        guard mode == .search || !searchText.isEmpty else { return }
        searchText = ""
        await load()
    }

    /// Set once the surface has gone away, so a tunnel that finishes connecting
    /// *after* teardown is released immediately instead of leaking.
    private var isTornDown = false

    /// Releases any remote tunnel (macOS `ssh -L` forward) when the surface goes away.
    func tearDown() async {
        isTornDown = true
        let release = teardown
        teardown = nil
        client = nil
        bankID = nil
        await release?()
    }

    private func resolvedClient() async throws -> (HindsightAPIClient, String) {
        if let client, let bankID { return (client, bankID) }
        isTornDown = false
        let resolution = try await HindsightEndpointResolver.resolve(
            profile: profile,
            profileName: profileName,
            transfer: transfer
        )
        let resolved: HindsightAPIClient
        if let remotePort = resolution.remoteEmbeddedPort {
            guard let remoteTransport else {
                throw HindsightEndpointError.remoteEmbeddedUnsupported
            }
            let connection = try await remoteTransport.connect(remotePort: remotePort)
            // The surface may have gone away while `connect()` was in flight; if so
            // `tearDown()` already ran and saw a nil teardown, so release this fresh
            // forward now rather than leak the `ssh -L` process.
            if isTornDown {
                await connection.teardown()
                throw CancellationError()
            }
            teardown = connection.teardown
            resolved = HindsightAPIClient(
                baseURL: connection.baseURL,
                apiKey: resolution.endpoint.apiKey,
                tenant: resolution.endpoint.tenant,
                http: connection.http
            )
        } else {
            resolved = resolution.endpoint.makeClient()
        }
        client = resolved
        bankID = resolution.endpoint.bankID
        return (resolved, resolution.endpoint.bankID)
    }

    private func fail(_ error: Error) {
        browseError = HindsightBrowseError.classify(error)
        phase = .idle
    }
}

/// The **Hindsight** tab: a searchable, paginated list of stored memories with a
/// read-only detail pane. Shown only when Hindsight is the active provider.
struct HindsightBrowserView: View {
    let windowHarness: ServerWindowHarness

    @State private var model: HindsightBrowserModel?

    var body: some View {
        Group {
            if let model {
                content(model: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Hindsight")
        .task {
            if model == nil {
                let m = HindsightBrowserModel(
                    profile: windowHarness.profile,
                    profileName: windowHarness.hermesProfileName,
                    transfer: windowHarness.snapshotTransfer,
                    remoteTransport: HindsightTransportSeam.make(windowHarness: windowHarness)
                )
                model = m
                await m.load()
            }
        }
        // Release any remote ssh -L forward when the surface leaves.
        .onDisappear { Task { [model] in await model?.tearDown() } }
    }

    @ViewBuilder
    private func content(model: HindsightBrowserModel) -> some View {
        PlatformSplit(
            showsSecondary: Binding(
                get: { model.selection != nil },
                set: { if !$0 { model.selection = nil } }
            ),
            secondaryTitle: model.selected.map(memoryTitle)
        ) {
            primaryPane(model: model)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            detailPane(model: model)
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar(model: model) }
    }

    // MARK: - Primary pane

    @ViewBuilder
    private func primaryPane(model: HindsightBrowserModel) -> some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Loading memories…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle where model.browseError != nil:
                errorState(model: model)
            case .empty:
                emptyState(model: model)
            default:
                memoryList(model: model)
            }
        }
        .searchable(
            text: Binding(get: { model.searchText }, set: { model.searchText = $0 }),
            prompt: "Search memories"
        )
        .onSubmit(of: .search) { Task { await model.runSearch() } }
        // The native clear (X) empties the field without submitting, so restore
        // the full list when the query goes empty.
        .onChange(of: model.searchText) { _, newValue in
            if newValue.isEmpty { Task { await model.clearSearch() } }
        }
    }

    @ViewBuilder
    private func memoryList(model: HindsightBrowserModel) -> some View {
        List(selection: Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )) {
            ForEach(model.memories) { memory in
                HindsightMemoryRow(memory: memory)
                    .tag(memory.id)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = memory.id }
            }
            if model.canLoadMore {
                HStack {
                    Spacer()
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Load more") { Task { await model.loadMore() } }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                .onAppear { Task { await model.loadMore() } }
            }
        }
    }

    @ViewBuilder
    private func emptyState(model: HindsightBrowserModel) -> some View {
        ContentUnavailableView(
            model.searchText.isEmpty ? "No memories" : "No matches",
            systemImage: "sparkles",
            description: Text(
                model.searchText.isEmpty
                    ? "Hindsight has no stored memories for this bank yet."
                    : "No memories matched “\(model.searchText)”."
            )
        )
    }

    @ViewBuilder
    private func errorState(model: HindsightBrowserModel) -> some View {
        ContentUnavailableView {
            Label("Can't browse Hindsight", systemImage: "exclamationmark.triangle")
        } description: {
            Text(model.browseError?.guidance ?? "Something went wrong.")
        } actions: {
            Button("Retry") { Task { await model.load() } }
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(model: HindsightBrowserModel) -> some View {
        if let memory = model.selected {
            HindsightMemoryDetail(memory: memory)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbar(model: HindsightBrowserModel) -> some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.phase == .loading)
            .help("Reload memories from Hindsight")
        }
    }

    private func memoryTitle(_ memory: HindsightMemory) -> String {
        memory.text.isEmpty ? memory.id : String(memory.text.prefix(40))
    }
}

/// One memory row: a content preview, a relative timestamp, and tag chips.
private struct HindsightMemoryRow: View {
    let memory: HindsightMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(memory.text)
                .lineLimit(2)
                .font(.body)
            HStack(spacing: 8) {
                if let date = memory.date {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let type = memory.type, !type.isEmpty {
                    Text(type)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if !memory.tags.isEmpty {
                    Text(memory.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Read-only detail for a single memory: full content plus its metadata.
private struct HindsightMemoryDetail: View {
    let memory: HindsightMemory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(memory.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                if let date = memory.date {
                    field("When", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let type = memory.type, !type.isEmpty {
                    field("Type", value: type)
                }
                if let context = memory.context, !context.isEmpty {
                    field("Context", value: context)
                }
                if !memory.entities.isEmpty {
                    field("Entities", value: memory.entities.joined(separator: ", "))
                }
                if !memory.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(memory.tags, id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                }
                if let documentID = memory.documentID, !documentID.isEmpty {
                    field("Document", value: documentID)
                }
                if !memory.metadata.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Metadata")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(memory.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(alignment: .top, spacing: 6) {
                                Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(value).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }

                Text("ID \(memory.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func field(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A single tag rendered by kind: `session:` and `parent:` are both Hermes
    /// session ids, so each deep-links to its chat via the shared `EntityLink`
    /// (parent = the session this one was resumed/forked from). Any other tag is
    /// inert text.
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        switch HindsightTagRef.parse(tag) {
        case .session(let id):
            EntityLink("session · \(id)", systemImage: "bubble.left.and.bubble.right", ref: .session(id), style: .subtle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Open this memory's chat session")
        case .parentSession(let id):
            EntityLink("parent · \(id)", systemImage: "arrow.triangle.branch", ref: .session(id), style: .subtle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Open the parent chat session")
        case .plain(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
