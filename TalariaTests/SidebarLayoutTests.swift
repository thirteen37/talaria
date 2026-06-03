import Foundation
import Testing
@testable import Talaria

@MainActor
@Suite
struct SidebarLayoutTests {
    /// A throwaway `UserDefaults` suite so each test gets isolated, clean
    /// storage that never touches the real app domain.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SidebarLayoutTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test
    func defaultOrderMatchesManageOrderAndExcludesSessions() {
        let layout = SidebarLayout(defaults: makeDefaults())

        #expect(layout.orderedManageDestinations == BrowseDestination.manageOrder)
        #expect(!layout.orderedManageDestinations.contains(.sessions))
        // Nothing hidden by default.
        #expect(layout.visibleManageDestinations() == BrowseDestination.manageOrder)
    }

    @Test
    func movePersistsAndRoundTrips() {
        let defaults = makeDefaults()
        let layout = SidebarLayout(defaults: defaults)

        // Move the first page (.extensions) to the end.
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: layout.orderedManageDestinations.count)

        var expected = BrowseDestination.manageOrder
        let moved = expected.removeFirst()
        expected.append(moved)
        #expect(layout.orderedManageDestinations == expected)

        // A fresh store reading the same defaults sees the persisted order.
        let reloaded = SidebarLayout(defaults: defaults)
        #expect(reloaded.orderedManageDestinations == expected)
    }

    @Test
    func hideAndShowPersists() {
        let defaults = makeDefaults()
        let layout = SidebarLayout(defaults: defaults)

        layout.setHidden(.extensions, hidden: true)
        #expect(layout.isHidden(.extensions))
        #expect(!layout.visibleManageDestinations().contains(.extensions))
        // Hidden page still listed in the editable order (recoverable).
        #expect(layout.orderedManageDestinations.contains(.extensions))

        let reloaded = SidebarLayout(defaults: defaults)
        #expect(reloaded.isHidden(.extensions))

        layout.setHidden(.extensions, hidden: false)
        #expect(!layout.isHidden(.extensions))
        #expect(layout.visibleManageDestinations().contains(.extensions))
    }

    @Test
    func unknownStoredRawStringIsDropped() {
        let defaults = makeDefaults()
        // Seed an order containing a bogus raw value plus a real one.
        defaults.set(["bogusRemovedPage", BrowseDestination.extensions.rawValue], forKey: "sidebarOrder")

        let layout = SidebarLayout(defaults: defaults)

        #expect(!layout.orderedManageDestinations.contains { $0.rawValue == "bogusRemovedPage" })
        #expect(layout.orderedManageDestinations.contains(.extensions))
    }

    @Test
    func legacyConsolidatedRawStringsAreDroppedAndExtensionsAppended() {
        let defaults = makeDefaults()
        // A pre-consolidation user's stored order references the four removed
        // pages. They become unknown raw strings and are dropped; `.extensions`
        // is appended as a missing manage page.
        defaults.set(["skills", "tools", "mcp", "plugins"], forKey: "sidebarOrder")

        let layout = SidebarLayout(defaults: defaults)

        for legacy in ["skills", "tools", "mcp", "plugins"] {
            #expect(!layout.orderedManageDestinations.contains { $0.rawValue == legacy })
        }
        #expect(layout.orderedManageDestinations.contains(.extensions))
        // Every current manage page is present after reconcile.
        #expect(Set(layout.orderedManageDestinations) == Set(BrowseDestination.manageOrder))
    }

    @Test
    func sessionsStoredRawStringIsDropped() {
        let defaults = makeDefaults()
        // `.sessions` is valid but pinned — it must never enter the manage list.
        defaults.set([BrowseDestination.sessions.rawValue, BrowseDestination.extensions.rawValue], forKey: "sidebarOrder")

        let layout = SidebarLayout(defaults: defaults)

        #expect(!layout.orderedManageDestinations.contains(.sessions))
    }

    @Test
    func missingManageEntryIsAppended() {
        let defaults = makeDefaults()
        // Store only one page; every other `manageOrder` page should be appended.
        defaults.set([BrowseDestination.models.rawValue], forKey: "sidebarOrder")

        let layout = SidebarLayout(defaults: defaults)

        // First is the explicitly-stored page.
        #expect(layout.orderedManageDestinations.first == .models)
        // All manage pages are present.
        #expect(Set(layout.orderedManageDestinations) == Set(BrowseDestination.manageOrder))
        // The appended remainder keeps `manageOrder`'s relative ordering.
        let appended = Array(layout.orderedManageDestinations.dropFirst())
        let expectedAppended = BrowseDestination.manageOrder.filter { $0 != .models }
        #expect(appended == expectedAppended)
    }

    @Test
    func resetToDefaultClearsBothKeys() {
        let defaults = makeDefaults()
        let layout = SidebarLayout(defaults: defaults)

        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: layout.orderedManageDestinations.count)
        layout.setHidden(.extensions, hidden: true)

        layout.resetToDefault()

        #expect(layout.orderedManageDestinations == BrowseDestination.manageOrder)
        #expect(layout.visibleManageDestinations() == BrowseDestination.manageOrder)
        #expect(defaults.array(forKey: "sidebarOrder") == nil)
        #expect(defaults.array(forKey: "sidebarHidden") == nil)
    }
}
