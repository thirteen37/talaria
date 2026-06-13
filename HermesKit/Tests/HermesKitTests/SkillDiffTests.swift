import Foundation
import Testing
@testable import HermesKit

@Suite
struct SkillDiffTests {
    @Test
    func identicalTextIsAllUnchanged() {
        let text = "line one\nline two\nline three"
        let rows = SkillDiff.sideBySide(default: text, profile: text)
        #expect(rows.allSatisfy { !$0.changed })
        #expect(rows.map(\.left) == ["line one", "line two", "line three"])
        #expect(rows.map(\.right) == ["line one", "line two", "line three"])
    }

    @Test
    func lineOnlyInDefaultIsLeftWithBlankRight() {
        // default has an extra middle line the profile lacks.
        let rows = SkillDiff.sideBySide(default: "a\nb\nc", profile: "a\nc")
        let changed = rows.filter(\.changed)
        #expect(changed.count == 1)
        #expect(changed.first?.left == "b")
        #expect(changed.first?.right == nil)
    }

    @Test
    func lineOnlyInProfileIsRightWithBlankLeft() {
        let rows = SkillDiff.sideBySide(default: "a\nc", profile: "a\nb\nc")
        let changed = rows.filter(\.changed)
        #expect(changed.count == 1)
        #expect(changed.first?.left == nil)
        #expect(changed.first?.right == "b")
    }

    @Test
    func modifiedLineIsPairedSideBySide() {
        // The middle line differs — it pairs into one changed row with both sides.
        let rows = SkillDiff.sideBySide(default: "a\nDEFAULT\nc", profile: "a\nPROFILE\nc")
        let changed = rows.filter(\.changed)
        #expect(changed.count == 1)
        #expect(changed.first?.left == "DEFAULT")
        #expect(changed.first?.right == "PROFILE")
        // The unchanged anchors survive on both sides.
        #expect(rows.first?.left == "a")
        #expect(rows.last?.right == "c")
    }

    @Test
    func hasDifferencesReflectsAnyChange() {
        #expect(!SkillDiff.sideBySide(default: "x\ny", profile: "x\ny").contains { $0.changed })
        #expect(SkillDiff.sideBySide(default: "x", profile: "y").contains { $0.changed })
    }
}
