import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesPersonalityTests {
    /// A config with one string personality, one structured personality, an
    /// active `system_prompt`, and an unrelated key that must never be touched.
    private func sampleConfig(activePrompt: String = "You are helpful.") -> JSONValue {
        .object([
            "model": .string("anthropic/claude-sonnet-4.6"),
            "agent": .object([
                "system_prompt": .string(activePrompt),
                "personalities": .object([
                    "helper": .string("You are helpful."),
                    "coder": .object([
                        "description": .string("A coding helper"),
                        "system_prompt": .string("You write code."),
                        "tone": .string("concise"),
                        "style": .string("use code examples"),
                    ]),
                ]),
            ]),
        ])
    }

    // MARK: - parse

    @Test
    func parseReadsStringAndStructuredEntriesSortedWithActivePrompt() {
        let (items, activePrompt) = HermesPersonality.parse(sampleConfig())

        #expect(activePrompt == "You are helpful.")
        // Sorted by name: coder before helper.
        #expect(items.map(\.name) == ["coder", "helper"])
        // Structured entry exposes its system_prompt as the editable text.
        #expect(items[0].prompt == "You write code.")
        // String entry's editable text is the string itself.
        #expect(items[1].prompt == "You are helpful.")
    }

    @Test
    func parseMissingPersonalitiesYieldsEmptyAndBlankActive() {
        let (items, activePrompt) = HermesPersonality.parse(.object(["model": .string("x")]))
        #expect(items.isEmpty)
        #expect(activePrompt == "")
    }

    // MARK: - resolvedPrompt

    @Test
    func resolvedPromptRoundTripsStringAndStructured() {
        #expect(HermesPersonality.resolvedPrompt(for: .string("You are helpful.")) == "You are helpful.")

        let structured = JSONValue.object([
            "system_prompt": .string("You write code."),
            "tone": .string("concise"),
            "style": .string("use code examples"),
        ])
        #expect(
            HermesPersonality.resolvedPrompt(for: structured)
                == "You write code.\nTone: concise\nStyle: use code examples"
        )
    }

    @Test
    func resolvedPromptStructuredWithoutToneOrStyleIsJustSystemPrompt() {
        let structured = JSONValue.object([
            "description": .string("A helper"),
            "system_prompt": .string("You are helpful."),
        ])
        #expect(HermesPersonality.resolvedPrompt(for: structured) == "You are helpful.")
    }

    // MARK: - upsert

    @Test
    func upsertAddsNewStringEntry() {
        let config = sampleConfig()
        let updated = HermesPersonality.upsert(name: "pirate", prompt: "Arr matey.", into: config)

        let map = HermesPersonality.personalitiesMap(in: updated)
        #expect(map["pirate"] == .string("Arr matey."))
        // Existing entries untouched.
        #expect(map["helper"] == .string("You are helpful."))
    }

    @Test
    func upsertEditingStructuredEntryPreservesExtraFields() {
        let config = sampleConfig()
        let updated = HermesPersonality.upsert(name: "coder", prompt: "You write tests first.", into: config)

        guard case let .object(coder)? = HermesPersonality.personalitiesMap(in: updated)["coder"] else {
            Issue.record("expected structured coder entry")
            return
        }
        #expect(coder["system_prompt"] == .string("You write tests first."))
        // description/tone/style preserved.
        #expect(coder["description"] == .string("A coding helper"))
        #expect(coder["tone"] == .string("concise"))
        #expect(coder["style"] == .string("use code examples"))
    }

    @Test
    func upsertRenameRemovesOldKeyAndKeepsValue() {
        let config = sampleConfig()
        // Rename structured "coder" -> "engineer", editing its prompt.
        let updated = HermesPersonality.upsert(
            name: "engineer",
            prompt: "You write Swift.",
            into: config,
            oldName: "coder"
        )

        let map = HermesPersonality.personalitiesMap(in: updated)
        #expect(map["coder"] == nil)
        guard case let .object(engineer)? = map["engineer"] else {
            Issue.record("expected migrated structured entry")
            return
        }
        #expect(engineer["system_prompt"] == .string("You write Swift."))
        #expect(engineer["tone"] == .string("concise"))
    }

    // MARK: - remove

    @Test
    func removeActivePersonalityClearsSystemPrompt() {
        // "helper" resolves to the active prompt, so removing it clears the overlay.
        let config = sampleConfig(activePrompt: "You are helpful.")
        let updated = HermesPersonality.remove(name: "helper", from: config)

        let (items, activePrompt) = HermesPersonality.parse(updated)
        #expect(items.map(\.name) == ["coder"])
        #expect(activePrompt == "")
    }

    @Test
    func removeInactivePersonalityLeavesSystemPromptIntact() {
        // Active prompt matches "helper"; removing "coder" must not clear it.
        let config = sampleConfig(activePrompt: "You are helpful.")
        let updated = HermesPersonality.remove(name: "coder", from: config)

        let (_, activePrompt) = HermesPersonality.parse(updated)
        #expect(activePrompt == "You are helpful.")
    }

    // MARK: - setActive

    @Test
    func setActiveWritesAndEmptyStringClears() {
        let config = sampleConfig(activePrompt: "")
        let active = HermesPersonality.setActive(resolvedPrompt: "You write code.", in: config)
        #expect(HermesPersonality.parse(active).activePrompt == "You write code.")

        let cleared = HermesPersonality.setActive(resolvedPrompt: "", in: active)
        #expect(HermesPersonality.parse(cleared).activePrompt == "")
    }

    // MARK: - round-trip

    @Test
    func mutationsLeaveUnrelatedConfigKeysUntouched() {
        let config = sampleConfig()
        let updated = HermesPersonality.upsert(name: "pirate", prompt: "Arr.", into: config)
        let removed = HermesPersonality.remove(name: "pirate", from: updated)
        let active = HermesPersonality.setActive(resolvedPrompt: "You write code.", in: removed)

        // The top-level `model` key is never disturbed by any personality op.
        guard case let .object(root) = active else {
            Issue.record("expected object root")
            return
        }
        #expect(root["model"] == .string("anthropic/claude-sonnet-4.6"))
    }
}
