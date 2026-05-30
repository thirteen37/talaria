import HermesKit
import SwiftUI

@MainActor
@Observable
final class SoulEditingState: Identifiable {
    let profileName: String
    nonisolated var id: String { profileName }

    var text = ""
    private(set) var original: String?
    var isLoading = false
    var lastError: String?
    var dashboardUnavailable = false

    private let defaultClientProvider: @MainActor () -> DashboardClient?
    private let serverProfile: ServerProfile
    private let transfer: RemoteSnapshotTransfer?
    private var loadTask: Task<Void, Never>?

    init(
        profileName: String,
        defaultClient: @escaping @MainActor () -> DashboardClient?,
        serverProfile: ServerProfile,
        transfer: RemoteSnapshotTransfer?
    ) {
        self.profileName = profileName
        self.defaultClientProvider = defaultClient
        self.serverProfile = serverProfile
        self.transfer = transfer
    }

    var isDirty: Bool {
        original.map { $0 != text && !dashboardUnavailable } ?? false
    }

    var canSave: Bool {
        isDirty && !isLoading && !dashboardUnavailable
    }

    func load() {
        let previous = loadTask
        loadTask = Task { [weak self] in
            await previous?.value
            await self?.performLoad()
        }
    }

    private func performLoad() async {
        isLoading = true
        defer { isLoading = false }

        if let client = defaultClientProvider() {
            do {
                let content = try await client.getSoul()
                if Task.isCancelled { return }
                text = content
                original = content
                dashboardUnavailable = false
                lastError = nil
            } catch {
                if Task.isCancelled { return }
                lastError = error.localizedDescription
            }
        } else {
            await loadDegraded()
        }
    }

    func reloadIfDashboardAppeared() {
        guard dashboardUnavailable, defaultClientProvider() != nil else { return }
        load()
    }

    private func loadDegraded() async {
        if Task.isCancelled { return }
        dashboardUnavailable = true
        original = nil
        do {
            let content = try await HermesSoulReader.read(
                profile: serverProfile,
                profileName: profileName,
                transfer: transfer
            )
            if Task.isCancelled { return }
            text = content
            lastError = nil
        } catch {
            if Task.isCancelled { return }
            text = ""
        }
    }

    func save() async {
        guard canSave else { return }
        isLoading = true
        defer { isLoading = false }
        guard let client = defaultClientProvider() else {
            lastError = "Dashboard is unavailable; can't save."
            return
        }
        do {
            try await client.updateSoul(text)
            load()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func teardown() async {
        loadTask?.cancel()
        await loadTask?.value
        loadTask = nil
    }
}
