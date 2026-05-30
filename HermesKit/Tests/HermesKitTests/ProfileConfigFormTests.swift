import Foundation
import Testing
@testable import HermesKit

@Suite
struct ProfileConfigFormTests {
    // MARK: - make()

    @Test
    func resolvesNestedDotpathValue() throws {
        let schema = DashboardConfigSchema(
            fields: ["terminal.backend": field("terminal.backend", .select, category: "terminal", options: ["local", "docker"])],
            orderedKeys: ["terminal.backend"],
            categoryOrder: ["terminal"]
        )
        let config = JSONValue.object(["terminal": .object(["backend": .string("docker")])])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        let row = try #require(form.field(for: "terminal.backend"))
        #expect(row.value == .string("docker"))
        #expect(row.category == "terminal")
    }

    @Test
    func resolvesNormalizedTopLevelModelKeys() throws {
        let schema = DashboardConfigSchema(
            fields: [
                "model": field("model", .string, category: "general"),
                "model_context_length": field("model_context_length", .number, category: "general"),
            ],
            orderedKeys: ["model", "model_context_length"],
            categoryOrder: ["general"]
        )
        let config = JSONValue.object([
            "model": .string("anthropic/claude-sonnet-4.6"),
            "model_context_length": .number(200000),
        ])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        #expect(form.field(for: "model")?.value == .string("anthropic/claude-sonnet-4.6"))
        #expect(form.field(for: "model_context_length")?.value == .number(200000))
    }

    @Test
    func coercesListValue() throws {
        let schema = DashboardConfigSchema(
            fields: ["agent.toolsets": field("agent.toolsets", .list, category: "agent")],
            orderedKeys: ["agent.toolsets"],
            categoryOrder: ["agent"]
        )
        let config = JSONValue.object(["agent": .object(["toolsets": .array([.string("files"), .string("web")])])])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        #expect(form.field(for: "agent.toolsets")?.value == .list(["files", "web"]))
    }

    @Test
    func keepsSelectValueNotInOptionsAsCustomEntry() throws {
        let schema = DashboardConfigSchema(
            fields: ["terminal.backend": field("terminal.backend", .select, category: "terminal", options: ["local", "docker"])],
            orderedKeys: ["terminal.backend"],
            categoryOrder: ["terminal"]
        )
        // A value the schema's option list doesn't know about must survive as a
        // custom entry rather than being dropped or reset to a default.
        let config = JSONValue.object(["terminal": .object(["backend": .string("kubernetes")])])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        #expect(form.field(for: "terminal.backend")?.value == .string("kubernetes"))
    }

    @Test
    func coercesBooleanValue() throws {
        let schema = DashboardConfigSchema(
            fields: ["agent.streaming": field("agent.streaming", .boolean, category: "agent")],
            orderedKeys: ["agent.streaming"],
            categoryOrder: ["agent"]
        )
        let config = JSONValue.object(["agent": .object(["streaming": .bool(true)])])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        #expect(form.field(for: "agent.streaming")?.value == .bool(true))
    }

    @Test
    func missingValueBecomesMissing() throws {
        let schema = DashboardConfigSchema(
            fields: ["agent.timeout": field("agent.timeout", .number, category: "agent")],
            orderedKeys: ["agent.timeout"],
            categoryOrder: ["agent"]
        )
        let config = JSONValue.object([:])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        #expect(form.field(for: "agent.timeout")?.value == .missing)
    }

    @Test
    func schemaLessKeysLandInTrailingOtherCategory() throws {
        let schema = DashboardConfigSchema(
            fields: ["model": field("model", .string, category: "general")],
            orderedKeys: ["model"],
            categoryOrder: ["general"]
        )
        let config = JSONValue.object([
            "model": .string("anthropic/x"),
            "custom_flag": .bool(true),
            "custom_label": .string("hello"),
        ])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        let categories = form.categories.map(\.name)
        #expect(categories.last == "other")
        let other = try #require(form.categories.first { $0.name == "other" })
        // Unmodeled keys sort alphabetically for deterministic display.
        #expect(other.fields.map(\.key) == ["custom_flag", "custom_label"])
        #expect(other.fields.first?.value == .bool(true))
    }

    @Test
    func groupsCategoriesInCategoryOrder() throws {
        let schema = DashboardConfigSchema(
            fields: [
                "model": field("model", .string, category: "general"),
                "agent.timeout": field("agent.timeout", .number, category: "agent"),
                "terminal.backend": field("terminal.backend", .string, category: "terminal"),
            ],
            orderedKeys: ["model", "agent.timeout", "terminal.backend"],
            // `display` is listed but has no fields → must be skipped, not shown empty.
            categoryOrder: ["general", "agent", "display", "terminal"]
        )
        let config = JSONValue.object([
            "model": .string("x"),
            "agent": .object(["timeout": .number(30)]),
            "terminal": .object(["backend": .string("local")]),
        ])

        let form = ProfileConfigForm.make(schema: schema, config: config)

        #expect(form.categories.map(\.name) == ["general", "agent", "terminal"])
    }

    // MARK: - merged()

    @Test
    func mergePreservesUnknownAndUneditedKeys() throws {
        // The non-destructive-PUT guarantee: starting from the original GET
        // object, only edited dotpaths change; every other key passes through.
        let original = JSONValue.object([
            "model": .string("anthropic/a"),
            "terminal": .object([
                "backend": .string("local"),
                "custom_extra": .string("keep-me"),
            ]),
            "untouched_section": .object(["deep": .object(["value": .number(7)])]),
        ])
        let edits: [String: ConfigValue] = ["terminal.backend": .string("docker")]

        let merged = ProfileConfigForm.merged(into: original, edits: edits)

        guard case .object(let root) = merged,
              case .object(let terminal) = root["terminal"] else {
            Issue.record("expected object structure")
            return
        }
        #expect(terminal["backend"] == .string("docker"))
        #expect(terminal["custom_extra"] == .string("keep-me"))
        #expect(root["model"] == .string("anthropic/a"))
        #expect(root["untouched_section"] == .object(["deep": .object(["value": .number(7)])]))
    }

    @Test
    func mergeCoercesValueTypesByEdit() throws {
        let original = JSONValue.object(["model_context_length": .number(0), "agent": .object(["streaming": .bool(false)])])
        let edits: [String: ConfigValue] = [
            "model_context_length": .number(200000),
            "agent.streaming": .bool(true),
        ]

        let merged = ProfileConfigForm.merged(into: original, edits: edits)

        guard case .object(let root) = merged,
              case .object(let agent) = root["agent"] else {
            Issue.record("expected object structure")
            return
        }
        #expect(root["model_context_length"] == .number(200000))
        #expect(agent["streaming"] == .bool(true))
    }

    @Test
    func mergeCreatesMissingIntermediateObjects() throws {
        // Editing a field whose section is absent from the original must create
        // the intermediate object rather than dropping the edit.
        let original = JSONValue.object(["model": .string("x")])
        let edits: [String: ConfigValue] = ["agent.timeout": .number(45)]

        let merged = ProfileConfigForm.merged(into: original, edits: edits)

        guard case .object(let root) = merged,
              case .object(let agent) = root["agent"] else {
            Issue.record("expected agent object to be created")
            return
        }
        #expect(agent["timeout"] == .number(45))
        #expect(root["model"] == .string("x"))
    }

    @Test
    func mergePreservesNumericListElementTypes() throws {
        // The original list held numbers; editing it via stringified rows must
        // coerce edited elements back to numbers (round-trip fidelity), not turn
        // them into quoted strings the server would reject.
        let original = JSONValue.object(["weights": .array([.number(1), .number(2)])])
        let edits: [String: ConfigValue] = ["weights": .list(["10", "2"])]

        let merged = ProfileConfigForm.merged(into: original, edits: edits)

        guard case .object(let root) = merged else {
            Issue.record("expected object")
            return
        }
        #expect(root["weights"] == .array([.number(10), .number(2)]))
    }

    @Test
    func mergeWritesStringListByDefault() throws {
        let original = JSONValue.object(["agent": .object(["toolsets": .array([.string("files")])])])
        let edits: [String: ConfigValue] = ["agent.toolsets": .list(["files", "web"])]

        let merged = ProfileConfigForm.merged(into: original, edits: edits)

        guard case .object(let root) = merged,
              case .object(let agent) = root["agent"] else {
            Issue.record("expected object")
            return
        }
        #expect(agent["toolsets"] == .array([.string("files"), .string("web")]))
    }

    // MARK: - edits(from:base:schema:)

    @Test
    func editsCapturesOnlyChangedLeavesCoercedBySchema() throws {
        let schema = DashboardConfigSchema(
            fields: ["terminal.backend": field("terminal.backend", .select, category: "terminal", options: ["local", "docker"])],
            orderedKeys: ["terminal.backend"],
            categoryOrder: ["terminal"]
        )
        let base = JSONValue.object(["model": .string("a"), "terminal": .object(["backend": .string("local")])])
        let working = JSONValue.object(["model": .string("a"), "terminal": .object(["backend": .string("docker")])])

        let edits = ProfileConfigForm.edits(from: working, base: base, schema: schema)

        #expect(edits == ["terminal.backend": .string("docker")])
    }

    @Test
    func editsCapturesAddedKeyInferredWhenSchemaless() throws {
        let base = JSONValue.object(["model": .string("a")])
        let working = JSONValue.object(["model": .string("a"), "custom_flag": .bool(true)])

        let edits = ProfileConfigForm.edits(from: working, base: base, schema: nil)

        #expect(edits == ["custom_flag": .bool(true)])
    }

    @Test
    func editsIsEmptyWhenNothingChanged() throws {
        let config = JSONValue.object(["model": .string("a"), "agent": .object(["timeout": .number(30)])])

        let edits = ProfileConfigForm.edits(from: config, base: config, schema: nil)

        #expect(edits.isEmpty)
    }

    // MARK: - Helpers

    private func field(
        _ key: String,
        _ type: ConfigFieldType,
        category: String,
        options: [String]? = nil
    ) -> ConfigFieldSchema {
        ConfigFieldSchema(key: key, type: type, description: nil, category: category, options: options)
    }
}
