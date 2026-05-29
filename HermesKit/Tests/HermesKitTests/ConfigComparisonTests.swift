import Foundation
import Testing
@testable import HermesKit

@Suite
struct ConfigComparisonTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "yaml"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func comparison() throws -> ConfigComparison {
        let source = try HermesConfigDocument.parse(fixture("config-default"))
        let dest = try HermesConfigDocument.parse(fixture("config-work"))
        return ConfigComparison(source: source, dest: dest)
    }

    private func row(_ comparison: ConfigComparison, section: String, keyPath: String) throws -> ConfigRowComparison {
        let sec = try #require(comparison.sections.first(where: { $0.name == section }))
        return try #require(sec.rows.first(where: { $0.keyPath == keyPath }))
    }

    @Test
    func classifiesChangedScalar() throws {
        let c = try comparison()
        let r = try row(c, section: "model", keyPath: "model.default")
        #expect(r.status == .changed)
        #expect(r.sourceValue == "opus")
        #expect(r.destValue == "sonnet")
    }

    @Test
    func classifiesSameScalar() throws {
        let c = try comparison()
        let r = try row(c, section: "model", keyPath: "model.fallbacks")
        #expect(r.status == .same)
    }

    @Test
    func classifiesOnlyInSource() throws {
        let c = try comparison()
        let r = try row(c, section: "agent", keyPath: "agent.timeout")
        #expect(r.status == .onlyInSource)
        #expect(r.sourceValue == "30")
        #expect(r.destValue == nil)
    }

    @Test
    func classifiesOnlyInDest() throws {
        let c = try comparison()
        let r = try row(c, section: "agent", keyPath: "agent.retries")
        #expect(r.status == .onlyInDest)
        #expect(r.sourceValue == nil)
        #expect(r.destValue == "3")
    }

    @Test
    func unionsSectionsSourceOrderThenDestOnly() throws {
        let c = try comparison()
        #expect(c.sections.map(\.name) == ["general", "model", "agent", "terminal", "network", "display"])
    }

    @Test
    func reportsHasDifferences() throws {
        let c = try comparison()
        let network = try #require(c.sections.first(where: { $0.name == "network" }))
        #expect(network.hasDifferences == false)
        let model = try #require(c.sections.first(where: { $0.name == "model" }))
        #expect(model.hasDifferences == true)
        let display = try #require(c.sections.first(where: { $0.name == "display" }))
        #expect(display.hasDifferences == true)
    }
}
