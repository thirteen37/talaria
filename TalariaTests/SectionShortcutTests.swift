import SwiftUI
import Testing
@testable import Talaria

/// The pure `index → KeyEquivalent?` mapping behind the View menu's ⌘-digit
/// section shortcuts: ⌘1…⌘9 for the first nine, ⌘0 for the tenth, none beyond.
@Suite
struct SectionShortcutTests {
    @Test
    func firstNineMapToTheirOwnDigit() {
        for index in 0..<9 {
            #expect(SectionShortcut.keyEquivalent(forIndex: index)?.character == Character("\(index + 1)"))
        }
    }

    @Test
    func tenthMapsToZero() {
        #expect(SectionShortcut.keyEquivalent(forIndex: 9)?.character == "0")
    }

    @Test
    func eleventhAndBeyondGetNone() {
        #expect(SectionShortcut.keyEquivalent(forIndex: 10) == nil)
        #expect(SectionShortcut.keyEquivalent(forIndex: 99) == nil)
    }

    @Test
    func shortcutCarriesCommandModifier() {
        let shortcut = SectionShortcut.shortcut(forIndex: 0)
        #expect(shortcut?.modifiers == .command)
        #expect(shortcut?.key.character == "1")
        #expect(SectionShortcut.shortcut(forIndex: 10) == nil)
    }
}
