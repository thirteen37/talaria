import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardConfigSchemaTests {
    @Test
    func parsesFieldsWithInjectedDotpathKeys() throws {
        let schema = try DashboardConfigSchema(data: loadFixtureData("config-schema.json"))

        let model = try #require(schema.field(for: "model"))
        #expect(model.key == "model")
        #expect(model.type == .string)
        #expect(model.category == "general")
        #expect(model.description == "Default model (e.g. anthropic/claude-sonnet-4.6)")
        #expect(model.options == nil)
    }

    @Test
    func decodesSelectFieldWithOptions() throws {
        let schema = try DashboardConfigSchema(data: loadFixtureData("config-schema.json"))

        let backend = try #require(schema.field(for: "terminal.backend"))
        #expect(backend.type == .select)
        #expect(backend.options == ["local", "docker", "ssh", "modal"])
    }

    @Test
    func decodesNumberBooleanAndListTypes() throws {
        let schema = try DashboardConfigSchema(data: loadFixtureData("config-schema.json"))

        #expect(schema.field(for: "model_context_length")?.type == .number)
        #expect(schema.field(for: "agent.streaming")?.type == .boolean)
        #expect(schema.field(for: "agent.toolsets")?.type == .list)
    }

    @Test
    func unknownTypeFallsBackToString() throws {
        let schema = try DashboardConfigSchema(data: loadFixtureData("config-schema.json"))

        // An upstream Hermes can introduce a field type the app doesn't model
        // yet; it must degrade to a plain text field rather than fail decoding.
        #expect(schema.field(for: "experimental.flux_capacitor")?.type == .string)
    }

    @Test
    func preservesFieldInsertionOrder() throws {
        let schema = try DashboardConfigSchema(data: loadFixtureData("config-schema.json"))

        // The dashboard renders fields in the order Hermes emits them
        // (model_context_length injected right after model). Foundation's
        // JSONDecoder hashes object keys, so order must be parsed explicitly.
        #expect(schema.orderedKeys == [
            "model",
            "model_context_length",
            "agent.timeout",
            "agent.streaming",
            "agent.toolsets",
            "terminal.backend",
            "experimental.flux_capacitor",
        ])
    }

    @Test
    func exposesCategoryOrder() throws {
        let schema = try DashboardConfigSchema(data: loadFixtureData("config-schema.json"))

        #expect(schema.categoryOrder == ["general", "agent", "terminal", "display", "auxiliary"])
    }

    private func loadFixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures/Dashboard"
            )
        )
        return try Data(contentsOf: url)
    }
}
