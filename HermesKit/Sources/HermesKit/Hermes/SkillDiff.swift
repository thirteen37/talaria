import Foundation

/// One aligned row of a side-by-side text comparison: the `default` profile's
/// line on the left, the named profile's line on the right. A `nil` side is a
/// gap (the opposite side has a line this one lacks). `changed` is true unless
/// both sides carry the same line.
public struct SkillDiffRow: Equatable, Sendable, Identifiable {
    public let id: Int
    public let left: String?
    public let right: String?
    public let changed: Bool

    public init(id: Int, left: String?, right: String?, changed: Bool) {
        self.id = id
        self.left = left
        self.right = right
        self.changed = changed
    }
}

/// Pure line-level side-by-side diff (LCS-based), used by the Sync tab's skill
/// comparison panel. Lines unique to one side are paired with the corresponding
/// run on the other side so a modified line shows as one row with both versions,
/// rather than a staircase of one-sided rows.
public enum SkillDiff {
    public static func sideBySide(default leftText: String, profile rightText: String) -> [SkillDiffRow] {
        let a = leftText.components(separatedBy: "\n")
        let b = rightText.components(separatedBy: "\n")
        let matches = longestCommonSubsequence(a, b)

        var rows: [SkillDiffRow] = []
        var id = 0
        var i = 0
        var j = 0

        func emitChangedBlock(toI ci: Int, toJ cj: Int) {
            let leftBlock = a[i..<ci]
            let rightBlock = b[j..<cj]
            let leftLines = Array(leftBlock)
            let rightLines = Array(rightBlock)
            for k in 0..<max(leftLines.count, rightLines.count) {
                rows.append(SkillDiffRow(
                    id: id,
                    left: k < leftLines.count ? leftLines[k] : nil,
                    right: k < rightLines.count ? rightLines[k] : nil,
                    changed: true
                ))
                id += 1
            }
            i = ci
            j = cj
        }

        for (ci, cj) in matches {
            emitChangedBlock(toI: ci, toJ: cj)
            rows.append(SkillDiffRow(id: id, left: a[ci], right: b[cj], changed: false))
            id += 1
            i = ci + 1
            j = cj + 1
        }
        emitChangedBlock(toI: a.count, toJ: b.count)
        return rows
    }

    /// Index pairs `(i, j)` of the longest common subsequence of `a` and `b`.
    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var result: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                result.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
