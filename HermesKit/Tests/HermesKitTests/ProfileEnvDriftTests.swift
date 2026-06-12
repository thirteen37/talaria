import Foundation
import Testing
@testable import HermesKit

@Suite
struct ProfileEnvDriftTests {
    private func entry(_ key: String, _ value: String) -> EnvFileEntry {
        EnvFileEntry(key: key, value: value)
    }

    @Test
    func keyMissingFromProfileIsMissing() {
        let drift = ProfileEnvDriftPlanner.drift(
            profileName: "work",
            defaultEntries: [entry("OPENAI_API_KEY", "sk-supersecretvalue")],
            profileEntries: []
        )
        let item = try! #require(drift.items.first)
        #expect(item.key == "OPENAI_API_KEY")
        #expect(item.kind == .missing)
        #expect(item.redactedProfileValue == nil)
        #expect(drift.missingCount == 1)
    }

    @Test
    func differingValueIsValueDiffers() {
        let drift = ProfileEnvDriftPlanner.drift(
            profileName: "work",
            defaultEntries: [entry("ANTHROPIC_API_KEY", "sk-newvalue-rotated")],
            profileEntries: [entry("ANTHROPIC_API_KEY", "sk-oldvalue-staleee")]
        )
        let item = try! #require(drift.items.first)
        #expect(item.kind == .valueDiffers)
        #expect(item.redactedDefaultValue == redactEnvValue("sk-newvalue-rotated"))
        #expect(item.redactedProfileValue == redactEnvValue("sk-oldvalue-staleee"))
        #expect(drift.differingCount == 1)
    }

    @Test
    func identicalValuesProduceNoDrift() {
        let drift = ProfileEnvDriftPlanner.drift(
            profileName: "work",
            defaultEntries: [entry("SHARED_KEY", "same-value-here")],
            profileEntries: [entry("SHARED_KEY", "same-value-here")]
        )
        #expect(drift.isInSync)
        #expect(drift.items.isEmpty)
    }

    @Test
    func driftItemNeverCarriesPlaintext() {
        let secret = "sk-supersecretvalue123456789"
        let drift = ProfileEnvDriftPlanner.drift(
            profileName: "work",
            defaultEntries: [entry("OPENAI_API_KEY", secret)],
            profileEntries: []
        )
        let item = try! #require(drift.items.first)
        // The Equatable/CustomStringConvertible dump must not leak the secret.
        #expect(!String(describing: item).contains(secret))
        #expect(item.redactedDefaultValue == redactEnvValue(secret))
    }

    @Test
    func invalidKeyNamesAreExcludedFromCandidates() {
        let drift = ProfileEnvDriftPlanner.drift(
            profileName: "work",
            defaultEntries: [
                entry("VALID_KEY", "v1"),
                entry("1INVALID", "v2"),          // starts with a digit
                entry("has-dash", "v3"),          // dash not allowed
                entry("", "v4"),                  // empty
            ],
            profileEntries: []
        )
        #expect(drift.items.map(\.key) == ["VALID_KEY"])
    }

    @Test
    func keysOnlyInNamedProfileAreExtras() {
        let drift = ProfileEnvDriftPlanner.drift(
            profileName: "work",
            defaultEntries: [entry("SHARED", "same-value-here")],
            profileEntries: [entry("SHARED", "same-value-here"), entry("WORK_ONLY", "localsecret")]
        )
        #expect(drift.isInSync) // extras don't make it out of sync
        #expect(drift.extras.map(\.key) == ["WORK_ONLY"])
        #expect(drift.extras.first?.redactedValue == redactEnvValue("localsecret"))
    }

    @Test
    func keyValidation() {
        #expect(ProfileEnvDriftPlanner.isValidKey("OPENAI_API_KEY"))
        #expect(ProfileEnvDriftPlanner.isValidKey("_underscore"))
        #expect(ProfileEnvDriftPlanner.isValidKey("a1"))
        #expect(!ProfileEnvDriftPlanner.isValidKey("1leading"))
        #expect(!ProfileEnvDriftPlanner.isValidKey("has-dash"))
        #expect(!ProfileEnvDriftPlanner.isValidKey("has space"))
        #expect(!ProfileEnvDriftPlanner.isValidKey(""))
    }
}
