import Testing
@testable import Talaria

/// Pure-logic coverage for `ChatView.pagedAnchorIndex`, the page-step/clamp math
/// behind Page Up / Page Down scroll-back. Exercised off the `@MainActor` since
/// the helper is `nonisolated static`.
@Suite
struct ChatPageScrollTests {
    @Test
    func emptyTranscriptHasNoAnchor() {
        #expect(ChatView.pagedAnchorIndex(from: nil, direction: .up, count: 0) == nil)
        #expect(ChatView.pagedAnchorIndex(from: nil, direction: .down, count: 0) == nil)
    }

    @Test
    func nilAnchorStartsFromLastMessage() {
        // 20 messages, stride 5: Page Up from the bottom (index 19) → 14.
        #expect(ChatView.pagedAnchorIndex(from: nil, direction: .up, count: 20, stride: 5) == 14)
        // Page Down from the bottom clamps at the last index (already there).
        #expect(ChatView.pagedAnchorIndex(from: nil, direction: .down, count: 20, stride: 5) == 19)
    }

    @Test
    func singleMessageAlwaysClampsToZero() {
        #expect(ChatView.pagedAnchorIndex(from: nil, direction: .up, count: 1, stride: 5) == 0)
        #expect(ChatView.pagedAnchorIndex(from: 0, direction: .up, count: 1, stride: 5) == 0)
        #expect(ChatView.pagedAnchorIndex(from: 0, direction: .down, count: 1, stride: 5) == 0)
    }

    @Test
    func steppingPastTopClampsToZero() {
        #expect(ChatView.pagedAnchorIndex(from: 3, direction: .up, count: 20, stride: 5) == 0)
    }

    @Test
    func steppingPastBottomClampsToLast() {
        #expect(ChatView.pagedAnchorIndex(from: 17, direction: .down, count: 20, stride: 5) == 19)
    }

    @Test
    func walksByStrideFromTrackedAnchor() {
        // From the tracked anchor 14, successive Page Ups walk 9 → 4 → 0 (clamped).
        #expect(ChatView.pagedAnchorIndex(from: 14, direction: .up, count: 20, stride: 5) == 9)
        #expect(ChatView.pagedAnchorIndex(from: 9, direction: .up, count: 20, stride: 5) == 4)
        #expect(ChatView.pagedAnchorIndex(from: 4, direction: .up, count: 20, stride: 5) == 0)
        // And Page Down walks back toward the live tail.
        #expect(ChatView.pagedAnchorIndex(from: 4, direction: .down, count: 20, stride: 5) == 9)
    }
}
