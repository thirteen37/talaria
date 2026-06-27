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
    func storedOrderIsReconciledToCurrentManagePages() {
        let defaults = makeDefaults()
        defaults.set(
            ["bogusRemovedPage", BrowseDestination.sessions.rawValue, BrowseDestination.models.rawValue],
            forKey: "sidebarOrder"
        )

        let layout = SidebarLayout(defaults: defaults)

        #expect(layout.orderedManageDestinations.first == .models)
        #expect(!layout.orderedManageDestinations.contains(.sessions))
        #expect(Set(layout.orderedManageDestinations) == Set(BrowseDestination.manageOrder))
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
