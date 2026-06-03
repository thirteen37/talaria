import Testing
@testable import Talaria

@Suite
struct RevealableSecretFieldTests {
    // MARK: - action

    @Test
    func showingAlwaysHides() {
        // Hiding is independent of the other inputs.
        for textIsEmpty in [true, false] {
            for canReveal in [true, false] {
                #expect(
                    RevealableSecret.action(showKey: true, textIsEmpty: textIsEmpty, canReveal: canReveal)
                        == .toggleMask(false)
                )
            }
        }
    }

    @Test
    func emptyAndRevealableFetches() {
        #expect(
            RevealableSecret.action(showKey: false, textIsEmpty: true, canReveal: true) == .fetch
        )
    }

    @Test
    func emptyButNotRevealableShowsTyped() {
        // Nothing stored to fetch (e.g. an unset secret) → just reveal typing.
        #expect(
            RevealableSecret.action(showKey: false, textIsEmpty: true, canReveal: false) == .toggleMask(true)
        )
    }

    @Test
    func nonEmptyNeverRefetches() {
        // A field that already holds text just toggles visibility — re-fetching
        // would clobber typed input and spend a rate-limited reveal.
        #expect(
            RevealableSecret.action(showKey: false, textIsEmpty: false, canReveal: true) == .toggleMask(true)
        )
        #expect(
            RevealableSecret.action(showKey: false, textIsEmpty: false, canReveal: false) == .toggleMask(true)
        )
    }

    // MARK: - showsEye

    @Test
    func secretAlwaysShowsEye() {
        for canReveal in [true, false] {
            for textIsEmpty in [true, false] {
                #expect(
                    RevealableSecret.showsEye(isSecret: true, canReveal: canReveal, textIsEmpty: textIsEmpty)
                )
            }
        }
    }

    @Test
    func nonSecretShowsEyeOnlyWhileEmptyAndRevealable() {
        // One-way "load value" affordance: offered only while empty + fetchable.
        #expect(RevealableSecret.showsEye(isSecret: false, canReveal: true, textIsEmpty: true))
        #expect(!RevealableSecret.showsEye(isSecret: false, canReveal: true, textIsEmpty: false))
        #expect(!RevealableSecret.showsEye(isSecret: false, canReveal: false, textIsEmpty: true))
        #expect(!RevealableSecret.showsEye(isSecret: false, canReveal: false, textIsEmpty: false))
    }
}
