import Testing
@testable import Talaria

/// The pure wrap-around index behind ⌃Tab / ⌃⇧Tab open-session cycling
/// (`SessionsStore.cycledSelectionIndex`).
@Suite
struct SessionTabCycleTests {
    @Test
    func emptyListHasNoNextIndex() {
        #expect(SessionsStore.cycledSelectionIndex(count: 0, current: nil, step: 1) == nil)
        #expect(SessionsStore.cycledSelectionIndex(count: 0, current: 0, step: -1) == nil)
    }

    @Test
    func forwardStepsAndWrapsToFirst() {
        #expect(SessionsStore.cycledSelectionIndex(count: 3, current: 0, step: 1) == 1)
        #expect(SessionsStore.cycledSelectionIndex(count: 3, current: 1, step: 1) == 2)
        #expect(SessionsStore.cycledSelectionIndex(count: 3, current: 2, step: 1) == 0)
    }

    @Test
    func backwardStepsAndWrapsToLast() {
        #expect(SessionsStore.cycledSelectionIndex(count: 3, current: 2, step: -1) == 1)
        #expect(SessionsStore.cycledSelectionIndex(count: 3, current: 1, step: -1) == 0)
        #expect(SessionsStore.cycledSelectionIndex(count: 3, current: 0, step: -1) == 2)
    }

    @Test
    func noCurrentSelectionStartsAtEdge() {
        // Forward lands on the first tab, backward on the last — so the first
        // ⌃Tab from a browse surface enters the tab strip predictably.
        #expect(SessionsStore.cycledSelectionIndex(count: 4, current: nil, step: 1) == 0)
        #expect(SessionsStore.cycledSelectionIndex(count: 4, current: nil, step: -1) == 3)
    }

    @Test
    func singleTabStaysPut() {
        #expect(SessionsStore.cycledSelectionIndex(count: 1, current: 0, step: 1) == 0)
        #expect(SessionsStore.cycledSelectionIndex(count: 1, current: 0, step: -1) == 0)
    }
}
