import Foundation
import Testing
@testable import HermesKit

@Suite
struct ConfigFormComparisonTests {
    // MARK: - Builders

    private func field(_ key: String, category: String, value: ConfigValue = .string("v")) -> ConfigFormField {
        ConfigFormField(key: key, schema: nil, value: value, category: category)
    }

    private func form(_ categories: [(String, [ConfigFormField])]) -> ProfileConfigForm {
        ProfileConfigForm(categories: categories.map { ConfigFormCategory(name: $0.0, fields: $0.1) })
    }

    private func row(_ result: [ComparisonCategory], category: String, key: String) throws -> ComparisonRow {
        let cat = try #require(result.first(where: { $0.name == category }))
        return try #require(cat.rows.first(where: { $0.key == key }))
    }

    // MARK: - Tests

    @Test
    func identicalFormsPairEverySide() throws {
        let a = form([("model", [field("model.default", category: "model")])])
        let b = form([("model", [field("model.default", category: "model")])])

        let result = alignedComparison(source: a, dest: b)

        let r = try row(result, category: "model", key: "model.default")
        #expect(r.sourceField != nil)
        #expect(r.destField != nil)
    }

    @Test
    func keyOnlyInSourceHasNilDest() throws {
        let source = form([("agent", [field("agent.timeout", category: "agent")])])
        let dest = form([("agent", [])])

        let result = alignedComparison(source: source, dest: dest)

        let r = try row(result, category: "agent", key: "agent.timeout")
        #expect(r.sourceField != nil)
        #expect(r.destField == nil)
    }

    @Test
    func keyOnlyInDestHasNilSource() throws {
        let source = form([("agent", [])])
        let dest = form([("agent", [field("agent.retries", category: "agent")])])

        let result = alignedComparison(source: source, dest: dest)

        let r = try row(result, category: "agent", key: "agent.retries")
        #expect(r.sourceField == nil)
        #expect(r.destField != nil)
    }

    @Test
    func withinCategorySourceKeysOrderThenDestOnlyAppended() throws {
        let source = form([("model", [
            field("model.default", category: "model"),
            field("model.fallbacks", category: "model"),
        ])])
        let dest = form([("model", [
            field("model.default", category: "model"),
            field("model.extra", category: "model"),
        ])])

        let result = alignedComparison(source: source, dest: dest)

        let model = try #require(result.first(where: { $0.name == "model" }))
        #expect(model.rows.map(\.key) == ["model.default", "model.fallbacks", "model.extra"])
    }

    @Test
    func categoryOnlyInDestAppendedAfterSourceCategories() throws {
        let source = form([("model", [field("model.default", category: "model")])])
        let dest = form([
            ("model", [field("model.default", category: "model")]),
            ("terminal", [field("terminal.backend", category: "terminal")]),
        ])

        let result = alignedComparison(source: source, dest: dest)

        #expect(result.map(\.name) == ["model", "terminal"])
        let terminal = try row(result, category: "terminal", key: "terminal.backend")
        #expect(terminal.sourceField == nil)
        #expect(terminal.destField != nil)
    }

    @Test
    func categoryOnlyInSourceKeptInSourceOrder() throws {
        let source = form([
            ("model", [field("model.default", category: "model")]),
            ("agent", [field("agent.timeout", category: "agent")]),
        ])
        let dest = form([("model", [field("model.default", category: "model")])])

        let result = alignedComparison(source: source, dest: dest)

        #expect(result.map(\.name) == ["model", "agent"])
        let agent = try row(result, category: "agent", key: "agent.timeout")
        #expect(agent.sourceField != nil)
        #expect(agent.destField == nil)
    }

    @Test
    func rowIdIsUnionedKeyNotPerSideField() throws {
        // A dest-only row's id must still be the key even though sourceField is nil.
        let source = form([("agent", [])])
        let dest = form([("agent", [field("agent.retries", category: "agent")])])

        let result = alignedComparison(source: source, dest: dest)

        let r = try row(result, category: "agent", key: "agent.retries")
        #expect(r.id == "agent.retries")
    }
}
