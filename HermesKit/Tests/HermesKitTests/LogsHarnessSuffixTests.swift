// This file lives in the HermesKit test bundle for test-runner convenience
// (the Talaria target doesn't ship Swift Testing yet), and re-implements
// the `suffix(of:after:)` algorithm so the unit tests don't need to import
// the Talaria module. If the algorithm in `LogsHarness` drifts, update the
// copy here in lockstep.
import Foundation
import Testing

@Suite
struct LogsHarnessSuffixTests {
    @Test
    func steadyStateAppendReturnsOnlyNewTail() {
        let previous = ["A", "B", "C", "D", "E"]
        let current = ["A", "B", "C", "D", "E", "F"]
        #expect(suffix(of: current, after: previous) == ["F"])
    }

    @Test
    func slidingWindowReturnsOnlyTheTrueNewLine() {
        // The dashboard returns a fixed-size tail. As a new line lands the
        // window slides — `current` doesn't extend `previous`, it shifts.
        // Without overlap-aware diffing the entire buffer gets re-appended
        // on every poll.
        let previous = ["A", "B", "C", "D", "E"]
        let current = ["B", "C", "D", "E", "F"]
        #expect(suffix(of: current, after: previous) == ["F"])
    }

    @Test
    func slidingWindowWithMultipleNewLines() {
        let previous = ["A", "B", "C", "D", "E"]
        let current = ["C", "D", "E", "F", "G"]
        #expect(suffix(of: current, after: previous) == ["F", "G"])
    }

    @Test
    func noChangeReturnsEmpty() {
        let lines = ["A", "B", "C"]
        #expect(suffix(of: lines, after: lines) == [])
    }

    @Test
    func unrelatedTailIsTreatedAsFullReset() {
        let previous = ["X", "Y", "Z"]
        let current = ["A", "B", "C"]
        #expect(suffix(of: current, after: previous) == ["A", "B", "C"])
    }

    @Test
    func emptyPreviousReturnsAllOfCurrent() {
        #expect(suffix(of: ["A", "B"], after: []) == ["A", "B"])
    }

    @Test
    func emptyCurrentReturnsEmpty() {
        #expect(suffix(of: [], after: ["A", "B"]) == [])
    }

    // Mirror of `Talaria.LogsHarness.suffix(of:after:)` — kept here so the
    // algorithm is unit-testable without importing the app target.
    private func suffix(of current: [String], after previous: [String]) -> [String] {
        if previous.isEmpty { return current }
        if current.isEmpty { return [] }
        for offset in 0..<previous.count {
            let trailingLen = previous.count - offset
            if current.count < trailingLen { continue }
            let previousTail = previous[offset...]
            let currentHead = current[..<trailingLen]
            if Array(previousTail) == Array(currentHead) {
                return Array(current[trailingLen...])
            }
        }
        return current
    }
}
