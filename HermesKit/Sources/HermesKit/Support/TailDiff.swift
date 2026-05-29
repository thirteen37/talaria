import Foundation

/// Diffs a freshly-fetched tail window against the previously-seen one.
///
/// Several dashboard surfaces poll an endpoint that returns the *full* current
/// line buffer on every hit (log tail, the `hermes update` action log) rather
/// than "lines since cursor X". Tracking a fixed integer offset breaks the
/// moment the buffer slides (fixed-size tail) or resets (log rotation, a new
/// action run that clears its buffer): the offset then points into the wrong
/// place and either re-emits the whole buffer or emits nothing.
///
/// ``newSuffix(of:after:)`` instead diffs against the previous full snapshot,
/// so callers keep `previous = current` each poll and stay correct across
/// append, slide, and reset.
public enum TailDiff {
    /// Returns the lines in `current` that weren't already at the tail of
    /// `previous`. Finds the largest overlap where a suffix of `previous`
    /// equals a prefix of `current` and returns everything after it. Falls
    /// back to returning all of `current` when there's no overlap (treat as a
    /// full reset/rotation).
    public static func newSuffix(of current: [String], after previous: [String]) -> [String] {
        if previous.isEmpty { return current }
        if current.isEmpty { return [] }
        for offset in 0..<previous.count {
            let trailingLen = previous.count - offset
            if current.count < trailingLen { continue }
            if Array(previous[offset...]) == Array(current[..<trailingLen]) {
                return Array(current[trailingLen...])
            }
        }
        return current
    }
}
