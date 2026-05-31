import Foundation
import SwiftUI

/// Global, `UserDefaults`-backed customization for the Browse navigation list:
/// the user's preferred order of the manage pages plus which pages are hidden.
/// One layout for the whole app (like ``RecentServers``), shared by the desktop
/// sidebar and the iPhone Browse sheet.
///
/// Only the ``BrowseDestination/manageOrder`` pages are customizable —
/// `.sessions` stays pinned and is never part of this list.
@MainActor
@Observable
final class SidebarLayout {
    private static let orderKey = "sidebarOrder"
    private static let hiddenKey = "sidebarHidden"

    /// Stored order of the manage pages, already reconciled against the current
    /// ``BrowseDestination/manageOrder``: unknown/removed raw strings are
    /// dropped, `.sessions` is excluded, and any manage page missing from the
    /// stored order is appended (so pages added in a future build surface
    /// automatically at the end).
    private(set) var orderedManageDestinations: [BrowseDestination]
    private var hidden: Set<BrowseDestination>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
        self.orderedManageDestinations = Self.reconcile(storedOrder)
        let storedHidden = defaults.stringArray(forKey: Self.hiddenKey) ?? []
        self.hidden = Set(storedHidden.compactMap(BrowseDestination.init(rawValue:))
            .filter { $0 != .sessions })
    }

    /// The manage pages to render, in order, minus the hidden ones.
    func visibleManageDestinations() -> [BrowseDestination] {
        orderedManageDestinations.filter { !hidden.contains($0) }
    }

    func isHidden(_ destination: BrowseDestination) -> Bool {
        hidden.contains(destination)
    }

    func setHidden(_ destination: BrowseDestination, hidden shouldHide: Bool) {
        guard destination != .sessions else { return }
        if shouldHide {
            hidden.insert(destination)
        } else {
            hidden.remove(destination)
        }
        persistHidden()
    }

    /// Drag-reorder hook for the editor's `List`. Operates on the full ordered
    /// list and persists the result.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        orderedManageDestinations.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    /// Restores `manageOrder` with nothing hidden by clearing both stored keys.
    func resetToDefault() {
        orderedManageDestinations = BrowseDestination.manageOrder
        hidden = []
        defaults.removeObject(forKey: Self.orderKey)
        defaults.removeObject(forKey: Self.hiddenKey)
    }

    // MARK: - Persistence

    private func persistOrder() {
        defaults.set(orderedManageDestinations.map(\.rawValue), forKey: Self.orderKey)
    }

    private func persistHidden() {
        defaults.set(hidden.map(\.rawValue), forKey: Self.hiddenKey)
    }

    /// Maps stored raw strings to known manage pages (dropping unknown values
    /// and `.sessions`), then appends any manage page the stored order is
    /// missing — preserving `manageOrder`'s relative order for the remainder.
    private static func reconcile(_ stored: [String]) -> [BrowseDestination] {
        let manage = BrowseDestination.manageOrder
        let manageSet = Set(manage)
        var seen: Set<BrowseDestination> = []
        var result: [BrowseDestination] = []
        for raw in stored {
            guard let destination = BrowseDestination(rawValue: raw),
                  manageSet.contains(destination),
                  !seen.contains(destination) else { continue }
            seen.insert(destination)
            result.append(destination)
        }
        for destination in manage where !seen.contains(destination) {
            result.append(destination)
        }
        return result
    }
}
