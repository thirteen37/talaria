import Foundation
import Testing
@testable import HermesKit

@Suite
struct AuxiliaryModelConfigTests {
    private func config(_ json: String) -> JSONValue {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test
    func clearsBaseURLForOneTaskAndPreservesEverythingElse() {
        let input = config(#"""
        {
          "auxiliary": {
            "title_generation": {"provider": "binky-litellm", "model": "fast", "base_url": "http://grendahl.local:49437/v1"},
            "vision": {"provider": "x", "model": "y", "base_url": "http://keep/v1"}
          },
          "other": {"k": "v"}
        }
        """#)

        let result = AuxiliaryModelConfig.clearingBaseURL(forTask: "title_generation", in: input)

        guard case let .object(root) = result,
              case let .object(aux) = root["auxiliary"],
              case let .object(title) = aux["title_generation"],
              case let .object(vision) = aux["vision"] else {
            Issue.record("unexpected shape: \(result)")
            return
        }
        // Cleared on the target slot…
        #expect(title["base_url"] == nil)
        // …but provider/model on that slot survive.
        #expect(title["provider"] == .string("binky-litellm"))
        #expect(title["model"] == .string("fast"))
        // Sibling slot fully untouched.
        #expect(vision["base_url"] == .string("http://keep/v1"))
        // Unrelated top-level key preserved.
        #expect(root["other"] == .object(["k": .string("v")]))
    }

    @Test
    func clearsBaseURLForEveryTaskWhenTaskIsNil() {
        let input = config(#"""
        {
          "auxiliary": {
            "title_generation": {"provider": "auto", "model": "", "base_url": "http://grendahl.local:49437/v1"},
            "vision": {"provider": "auto", "model": "", "base_url": "http://x/v1"}
          }
        }
        """#)

        let result = AuxiliaryModelConfig.clearingBaseURL(forTask: nil, in: input)

        guard case let .object(root) = result, case let .object(aux) = root["auxiliary"] else {
            Issue.record("unexpected shape: \(result)")
            return
        }
        for key in ["title_generation", "vision"] {
            guard case let .object(slot) = aux[key] else {
                Issue.record("missing slot \(key)")
                return
            }
            #expect(slot["base_url"] == nil)
        }
    }

    @Test
    func returnsEqualValueWhenNoBaseURLToClear() {
        // Equality lets the caller skip a needless PUT.
        let input = config(#"""
        {"auxiliary": {"title_generation": {"provider": "binky-litellm", "model": "fast"}}}
        """#)

        let result = AuxiliaryModelConfig.clearingBaseURL(forTask: "title_generation", in: input)

        #expect(result == input)
    }

    @Test
    func returnsEqualValueWhenNoAuxiliaryMappingPresent() {
        let input = config(#"{"providers": {"a": {"base_url": "http://x/v1"}}}"#)

        let result = AuxiliaryModelConfig.clearingBaseURL(forTask: "title_generation", in: input)

        #expect(result == input)
    }

    @Test
    func clearingAnAbsentSlotIsANoOp() {
        let input = config(#"""
        {"auxiliary": {"vision": {"provider": "x", "model": "y", "base_url": "http://x/v1"}}}
        """#)

        let result = AuxiliaryModelConfig.clearingBaseURL(forTask: "title_generation", in: input)

        #expect(result == input)
    }
}
