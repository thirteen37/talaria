import Foundation
import Testing
@testable import HermesKit

@Suite
struct YAMLConfigCodecTests {
    @Test
    func parsesNestedMappingIntoObject() throws {
        let yaml = """
        model: anthropic/claude-sonnet-4.6
        model_context_length: 200000
        agent:
          streaming: true
          toolsets:
            - files
            - web
        """

        let value = try YAMLConfigCodec.jsonValue(fromYAML: yaml)

        guard case .object(let root) = value,
              case .object(let agent) = root["agent"] else {
            Issue.record("expected nested object")
            return
        }
        #expect(root["model"] == .string("anthropic/claude-sonnet-4.6"))
        #expect(root["model_context_length"] == .number(200000))
        #expect(agent["streaming"] == .bool(true))
        #expect(agent["toolsets"] == .array([.string("files"), .string("web")]))
    }

    @Test
    func emptyDocumentBecomesEmptyObject() throws {
        let value = try YAMLConfigCodec.jsonValue(fromYAML: "")
        #expect(value == .object([:]))
    }

    @Test
    func keepsQuotedNumericStringAsString() throws {
        // A quoted scalar must stay a string even when it looks numeric, so a
        // model name or version pin isn't silently coerced to a number.
        let value = try YAMLConfigCodec.jsonValue(fromYAML: "pin: \"123\"")
        guard case .object(let root) = value else { Issue.record("expected object"); return }
        #expect(root["pin"] == .string("123"))
    }

    @Test
    func throwsOnMalformedYAML() {
        #expect(throws: (any Error).self) {
            _ = try YAMLConfigCodec.jsonValue(fromYAML: "key: [unterminated")
        }
    }

    @Test
    func throwsWhenTopLevelIsNotAnObject() {
        // The config document is always a mapping; a bare list or scalar at the
        // root is a user mistake the editor must reject before any PUT.
        #expect(throws: (any Error).self) {
            _ = try YAMLConfigCodec.jsonValue(fromYAML: "- just\n- a\n- list")
        }
    }

    @Test
    func dumpsObjectToYAML() throws {
        let value = JSONValue.object([
            "model": .string("anthropic/x"),
            "model_context_length": .number(200000),
        ])

        let text = try YAMLConfigCodec.yaml(from: value)

        #expect(text.contains("model: anthropic/x"))
        // Whole numbers render without a trailing .0 so the YAML stays clean.
        #expect(text.contains("model_context_length: 200000"))
        #expect(!text.contains("200000.0"))
    }

    @Test
    func roundTripsThroughYAMLAndBack() throws {
        let original = JSONValue.object([
            "model": .string("anthropic/claude-sonnet-4.6"),
            "model_context_length": .number(0),
            "agent": .object([
                "streaming": .bool(false),
                "toolsets": .array([.string("files"), .string("web")]),
            ]),
        ])

        let text = try YAMLConfigCodec.yaml(from: original)
        let reparsed = try YAMLConfigCodec.jsonValue(fromYAML: text)

        #expect(reparsed == original)
    }
}
