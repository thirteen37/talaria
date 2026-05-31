// Tests the shared `TailDiff.newSuffix(of:after:)` used by the Logs tail
// poll (`LogsHarness`).
import Foundation
import Testing
@testable import HermesKit

@Suite
struct TailDiffTests {
    @Test
    func steadyStateAppendReturnsOnlyNewTail() {
        let previous = ["A", "B", "C", "D", "E"]
        let current = ["A", "B", "C", "D", "E", "F"]
        #expect(TailDiff.newSuffix(of: current, after: previous) == ["F"])
    }

    @Test
    func slidingWindowReturnsOnlyTheTrueNewLine() {
        // The dashboard returns a fixed-size tail. As a new line lands the
        // window slides — `current` doesn't extend `previous`, it shifts.
        // Without overlap-aware diffing the entire buffer gets re-appended
        // on every poll.
        let previous = ["A", "B", "C", "D", "E"]
        let current = ["B", "C", "D", "E", "F"]
        #expect(TailDiff.newSuffix(of: current, after: previous) == ["F"])
    }

    @Test
    func slidingWindowWithMultipleNewLines() {
        let previous = ["A", "B", "C", "D", "E"]
        let current = ["C", "D", "E", "F", "G"]
        #expect(TailDiff.newSuffix(of: current, after: previous) == ["F", "G"])
    }

    @Test
    func noChangeReturnsEmpty() {
        let lines = ["A", "B", "C"]
        #expect(TailDiff.newSuffix(of: lines, after: lines) == [])
    }

    @Test
    func unrelatedTailIsTreatedAsFullReset() {
        let previous = ["X", "Y", "Z"]
        let current = ["A", "B", "C"]
        #expect(TailDiff.newSuffix(of: current, after: previous) == ["A", "B", "C"])
    }

    @Test
    func bufferResetToShorterRunEmitsTheNewRunFromStart() {
        // The update-action case: a new run resets the buffer to fewer lines
        // than the previous run had. A fixed `dropFirst(oldCount)` would yield
        // nothing; the overlap diff treats it as a reset and emits the new run.
        let previous = ["old1", "old2", "old3", "old4", "old5"]
        let current = ["new1", "new2"]
        #expect(TailDiff.newSuffix(of: current, after: previous) == ["new1", "new2"])
    }

    @Test
    func emptyPreviousReturnsAllOfCurrent() {
        #expect(TailDiff.newSuffix(of: ["A", "B"], after: []) == ["A", "B"])
    }

    @Test
    func emptyCurrentReturnsEmpty() {
        #expect(TailDiff.newSuffix(of: [], after: ["A", "B"]) == [])
    }
}
