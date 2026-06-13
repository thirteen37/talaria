import Foundation
import Testing
@testable import HermesKit

@Suite
struct ProfileConfigDriftTests {
    // MARK: - Helpers

    private func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

    private func schema(_ fields: [ConfigFieldSchema]) -> DashboardConfigSchema {
        DashboardConfigSchema(
            fields: Dictionary(fields.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }),
            orderedKeys: fields.map(\.key),
            categoryOrder: []
        )
    }

    // MARK: - Curated scope

    @Test
    func curatedPrefixMatchesExactAndNestedDotpaths() {
        #expect(ConfigSyncScope.isCurated(dotpath: "model"))
        #expect(ConfigSyncScope.isCurated(dotpath: "providers.anthropic.api_key"))
        #expect(ConfigSyncScope.isCurated(dotpath: "custom_providers.x"))
        #expect(ConfigSyncScope.isCurated(dotpath: "fallback_providers.0"))
        #expect(ConfigSyncScope.isCurated(dotpath: "auxiliary.fast.model"))
        // `model_context_length` must NOT match the `model` prefix.
        #expect(!ConfigSyncScope.isCurated(dotpath: "model_context_length"))
        #expect(!ConfigSyncScope.isCurated(dotpath: "terminal.backend"))
    }

    @Test
    func auxiliaryBaseUrlIsExcludedFromPushEvenUnderShowAll() {
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work",
            defaultConfig: obj(["auxiliary": obj(["fast": obj(["base_url": .string("https://default")])])]),
            profileConfig: obj(["auxiliary": obj(["fast": obj(["base_url": .string("https://other")])])]),
            schema: nil
        )
        let item = try! #require(drift.items.first { $0.dotpath == "auxiliary.fast.base_url" })
        #expect(item.isCurated)          // it IS a curated section…
        #expect(!item.isPushable)        // …but never pushed
        // Excluded from the push payload even when curatedOnly == false (show all).
        #expect(drift.pushPayload(curatedOnly: false)["auxiliary.fast.base_url"] == nil)
    }

    // MARK: - Drift direction & kinds

    @Test
    func defaultValueWinsAsPushPayload() {
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work",
            defaultConfig: obj(["model": .string("anthropic/opus")]),
            profileConfig: obj(["model": .string("openai/gpt")]),
            schema: schema([ConfigFieldSchema(key: "model", type: .string, description: nil, category: "Model")])
        )
        let item = try! #require(drift.items.first { $0.dotpath == "model" })
        #expect(item.kind == .changed)
        #expect(item.defaultValue == .string("anthropic/opus"))
        #expect(item.profileValue == .string("openai/gpt"))
        #expect(drift.pushPayload(curatedOnly: true)["model"] == .string("anthropic/opus"))
    }

    @Test
    func keyAbsentFromProfileIsMissingInProfile() {
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work",
            defaultConfig: obj(["providers": obj(["anthropic": obj(["api_key": .string("sk-1")])])]),
            profileConfig: obj([:]),
            schema: nil
        )
        let item = try! #require(drift.items.first { $0.dotpath == "providers.anthropic.api_key" })
        #expect(item.kind == .missingInProfile)
        #expect(item.profileValue == nil)
        #expect(item.isPushable)
        #expect(drift.pushPayload(curatedOnly: true)["providers.anthropic.api_key"] == .string("sk-1"))
    }

    @Test
    func identicalConfigsAreInSync() {
        let same = obj(["model": .string("anthropic/opus"), "terminal": obj(["backend": .string("swiftterm")])])
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work", defaultConfig: same, profileConfig: same, schema: nil
        )
        #expect(drift.isInSync)
        #expect(drift.items.isEmpty)
    }

    // MARK: - Extras

    @Test
    func keysOnlyInNamedProfileAreExtrasAndNeverCandidates() {
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work",
            defaultConfig: obj(["model": .string("anthropic/opus")]),
            profileConfig: obj(["model": .string("anthropic/opus"), "experimental": obj(["flag": .bool(true)])]),
            schema: nil
        )
        #expect(drift.isInSync) // extras don't make the profile out of sync
        #expect(drift.extras.map(\.dotpath) == ["experimental.flag"])
        #expect(drift.pushPayload(curatedOnly: false)["experimental.flag"] == nil)
    }

    // MARK: - .raw unpushable

    @Test
    func typeMismatchedNumberRowIsUnpushable() {
        // Schema says `top_p` is a number, but default carries a non-numeric
        // string — it can't be coerced, so it's a read-only, unpushable row.
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work",
            defaultConfig: obj(["top_p": .string("not-a-number")]),
            profileConfig: obj(["top_p": .number(0.9)]),
            schema: schema([ConfigFieldSchema(key: "top_p", type: .number, description: nil, category: "Model")])
        )
        let item = try! #require(drift.items.first { $0.dotpath == "top_p" })
        #expect(!item.isPushable)
        #expect(drift.pushPayload(curatedOnly: false)["top_p"] == nil)
    }

    // MARK: - Category grouping

    @Test
    func categoryComesFromSchemaAndFallsBackToOther() {
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work",
            defaultConfig: obj(["model": .string("a"), "unknown_key": .string("x")]),
            profileConfig: obj(["model": .string("b"), "unknown_key": .string("y")]),
            schema: schema([ConfigFieldSchema(key: "model", type: .string, description: nil, category: "Model")])
        )
        #expect(drift.items.first { $0.dotpath == "model" }?.category == "Model")
        #expect(drift.items.first { $0.dotpath == "unknown_key" }?.category == ProfileConfigForm.otherCategoryName)
    }

    // MARK: - Push payload equals ProfileConfigForm.edits

    @Test
    func pushPayloadMatchesProfileConfigFormEdits() {
        let defaultConfig = obj([
            "model": .string("anthropic/opus"),
            "providers": obj(["anthropic": obj(["api_key": .string("sk-1")])]),
        ])
        let profileConfig = obj(["model": .string("openai/gpt")])
        let aSchema = schema([ConfigFieldSchema(key: "model", type: .string, description: nil, category: "Model")])
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work", defaultConfig: defaultConfig, profileConfig: profileConfig, schema: aSchema
        )
        let edits = ProfileConfigForm.edits(from: defaultConfig, base: profileConfig, schema: aSchema)
        #expect(drift.pushPayload(curatedOnly: false) == edits)
    }

    // MARK: - YAML bridge

    @Test
    func driftBridgesFromRawYAML() throws {
        let defaultYAML = """
        model: anthropic/claude-opus-4.8
        providers:
          anthropic:
            api_key: sk-default
        """
        let profileYAML = """
        model: openai/gpt-5
        """
        let defaultConfig = try YAMLConfigCodec.jsonValue(fromYAML: defaultYAML)
        let profileConfig = try YAMLConfigCodec.jsonValue(fromYAML: profileYAML)
        let drift = ProfileConfigDriftPlanner.drift(
            profileName: "work", defaultConfig: defaultConfig, profileConfig: profileConfig, schema: nil
        )
        #expect(drift.items.first { $0.dotpath == "model" }?.kind == .changed)
        #expect(drift.items.first { $0.dotpath == "providers.anthropic.api_key" }?.kind == .missingInProfile)
        // The push payload carries the default's value, not the profile's.
        #expect(drift.pushPayload(curatedOnly: false)["model"] == .string("anthropic/claude-opus-4.8"))
    }
}
