import Foundation
import Testing
@testable import Talaria

/// Covers `SessionsBrowser.Filter.matches` — the pure per-row predicate that
/// decides whether a session survives the active filters. Threshold filters
/// treat a nil field as "fails the floor" (an unknown value can't satisfy
/// "≥N"), which also lets a search query and the filters combine: lean search
/// rows (all numeric fields nil) drop out of any set floor while enriched rows
/// keep their real counts.
struct SessionsBrowserFilterTests {
    /// A fully-populated browse row.
    private func rich(
        source: String? = "acp",
        model: String? = "opus",
        isActive: Bool = false,
        messageCount: Int? = 40,
        toolCallCount: Int? = 5,
        tokenTotal: Int? = 250_000,
        costUsd: Double? = 2.50
    ) -> HermesSessionSummary {
        HermesSessionSummary(
            id: "rich",
            title: "Rich",
            isActive: isActive,
            model: model,
            messageCount: messageCount,
            toolCallCount: toolCallCount,
            tokenTotal: tokenTotal,
            costUsd: costUsd
        ).with(source: source)
    }

    /// A lean search-hit row: only id/title, every numeric field nil.
    private func lean() -> HermesSessionSummary {
        HermesSessionSummary(id: "lean", title: "snippet")
    }

    @Test
    func defaultFilterMatchesRichAndLean() {
        let filter = SessionsBrowser.Filter()
        #expect(filter.matches(rich()))
        #expect(filter.matches(lean()))
    }

    @Test
    func messageFloorExcludesBelowThreshold() {
        var filter = SessionsBrowser.Filter()
        filter.messageFloor = .atLeast20
        #expect(filter.matches(rich(messageCount: 20)))
        #expect(!filter.matches(rich(messageCount: 19)))
        #expect(!filter.matches(rich(messageCount: nil)))
        #expect(!filter.matches(lean()))
    }

    @Test
    func tokenFloorExcludesBelowThreshold() {
        var filter = SessionsBrowser.Filter()
        filter.tokenFloor = .atLeast100K
        #expect(filter.matches(rich(tokenTotal: 100_000)))
        #expect(!filter.matches(rich(tokenTotal: 99_999)))
        #expect(!filter.matches(rich(tokenTotal: nil)))
    }

    @Test
    func costFloorAboveZeroRequiresSpend() {
        var filter = SessionsBrowser.Filter()
        filter.costFloor = .aboveZero
        #expect(filter.matches(rich(costUsd: 0.01)))
        #expect(!filter.matches(rich(costUsd: 0)))
        #expect(!filter.matches(rich(costUsd: nil)))
    }

    @Test
    func costFloorAtLeastOne() {
        var filter = SessionsBrowser.Filter()
        filter.costFloor = .atLeast1
        #expect(filter.matches(rich(costUsd: 1.0)))
        #expect(!filter.matches(rich(costUsd: 0.99)))
    }

    @Test
    func hasToolCallsRequiresPositiveCount() {
        var filter = SessionsBrowser.Filter()
        filter.hasToolCalls = true
        #expect(filter.matches(rich(toolCallCount: 1)))
        #expect(!filter.matches(rich(toolCallCount: 0)))
        #expect(!filter.matches(rich(toolCallCount: nil)))
    }

    @Test
    func sourceAndModelStillFilter() {
        var filter = SessionsBrowser.Filter()
        filter.source = "acp"
        filter.model = "opus"
        #expect(filter.matches(rich(source: "acp", model: "opus")))
        #expect(!filter.matches(rich(source: "telegram", model: "opus")))
        #expect(!filter.matches(rich(source: "acp", model: "sonnet")))
        // A lean row (source/model nil) fails any set source/model filter.
        #expect(!filter.matches(lean()))
    }

    @Test
    func combinedFloorAndSourceFilter() {
        var filter = SessionsBrowser.Filter()
        filter.source = "acp"
        filter.messageFloor = .atLeast50
        #expect(filter.matches(rich(source: "acp", messageCount: 50)))
        #expect(!filter.matches(rich(source: "acp", messageCount: 49)))
        #expect(!filter.matches(rich(source: "telegram", messageCount: 80)))
    }

    @Test
    func isActiveTracksNewFields() {
        #expect(!SessionsBrowser.Filter().isActive)

        var floor = SessionsBrowser.Filter()
        floor.messageFloor = .atLeast5
        #expect(floor.isActive)

        var tools = SessionsBrowser.Filter()
        tools.hasToolCalls = true
        #expect(tools.isActive)
    }
}

private extension HermesSessionSummary {
    /// Convenience for setting `source` after the memberwise init (which keeps
    /// `source` mid-signature) in tests, keeping the row builders terse.
    func with(source: String?) -> HermesSessionSummary {
        var copy = self
        copy.source = source
        return copy
    }
}
