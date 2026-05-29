import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesConfigDocumentTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "yaml"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func flattensNestedMapsToDottedPaths() throws {
        let doc = try HermesConfigDocument.parse(fixture("config-default"))
        let model = try #require(doc.sections.first(where: { $0.name == "model" }))
        #expect(model.entries.contains(ConfigEntry(keyPath: "model.default", value: "opus")))
        let agent = try #require(doc.sections.first(where: { $0.name == "agent" }))
        #expect(agent.entries.contains(ConfigEntry(keyPath: "agent.max_turns", value: "10")))
        #expect(agent.entries.contains(ConfigEntry(keyPath: "agent.timeout", value: "30")))
    }

    @Test
    func rendersListAsSingleInlineEntry() throws {
        let doc = try HermesConfigDocument.parse(fixture("config-default"))
        let model = try #require(doc.sections.first(where: { $0.name == "model" }))
        let fallbacks = try #require(model.entries.first(where: { $0.keyPath == "model.fallbacks" }))
        #expect(fallbacks.value == "[sonnet, haiku]")
        // The list must be one entry, not one-per-index.
        #expect(model.entries.filter { $0.keyPath.hasPrefix("model.fallbacks") }.count == 1)
    }

    @Test
    func bucketsTopLevelScalarsIntoGeneralSection() throws {
        let doc = try HermesConfigDocument.parse(fixture("config-default"))
        let general = try #require(doc.sections.first(where: { $0.name == "general" }))
        #expect(general.entries.contains(ConfigEntry(keyPath: "log_level", value: "info")))
        // The synthetic general section sorts first.
        #expect(doc.sections.first?.name == "general")
    }

    @Test
    func preservesSectionOrderFromFile() throws {
        let doc = try HermesConfigDocument.parse(fixture("config-default"))
        #expect(doc.sections.map(\.name) == ["general", "model", "agent", "terminal", "network"])
    }

    @Test
    func throwsParseFailedOnMalformedYAML() {
        #expect(throws: HermesConfigError.self) {
            _ = try HermesConfigDocument.parse("key: [a, b")
        }
    }
}
