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

        // Move the first page (.skills) to the end.
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

        layout.setHidden(.tools, hidden: true)
        #expect(layout.isHidden(.tools))
        #expect(!layout.visibleManageDestinations().contains(.tools))
        // Hidden page still listed in the editable order (recoverable).
        #expect(layout.orderedManageDestinations.contains(.tools))

        let reloaded = SidebarLayout(defaults: defaults)
        #expect(reloaded.isHidden(.tools))

        layout.setHidden(.tools, hidden: false)
        #expect(!layout.isHidden(.tools))
        #expect(layout.visibleManageDestinations().contains(.tools))
    }

    @Test
    func unknownStoredRawStringIsDropped() {
        let defaults = makeDefaults()
        // Seed an order containing a bogus raw value plus a real one.
        defaults.set(["bogusRemovedPage", BrowseDestination.skills.rawValue], forKey: "sidebarOrder")

        let layout = SidebarLayout(defaults: defaults)

        #expect(!layout.orderedManageDestinations.contains { $0.rawValue == "bogusRemovedPage" })
        #expect(layout.orderedManageDestinations.contains(.skills))
    }

    @Test
    func sessionsStoredRawStringIsDropped() {
        let defaults = makeDefaults()
        // `.sessions` is valid but pinned — it must never enter the manage list.
        defaults.set([BrowseDestination.sessions.rawValue, BrowseDestination.skills.rawValue], forKey: "sidebarOrder")

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
        layout.setHidden(.tools, hidden: true)

        layout.resetToDefault()

        #expect(layout.orderedManageDestinations == BrowseDestination.manageOrder)
        #expect(layout.visibleManageDestinations() == BrowseDestination.manageOrder)
        #expect(defaults.array(forKey: "sidebarOrder") == nil)
        #expect(defaults.array(forKey: "sidebarHidden") == nil)
    }
}
