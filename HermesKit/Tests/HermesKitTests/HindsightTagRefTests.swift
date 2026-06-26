import Foundation
import Testing
@testable import HermesKit

@Suite
struct HindsightTagRefTests {
    @Test
    func parsesSessionTag() {
        #expect(HindsightTagRef.parse("session:20260617_092704_a68775") == .session(id: "20260617_092704_a68775"))
    }

    @Test
    func parsesParentTagAsSession() {
        // `parent:` is the *parent session* id (a resumed/forked-from session),
        // not a memory id — so it links to a chat session too.
        #expect(HindsightTagRef.parse("parent:20260613_200307_e3e478") == .parentSession(id: "20260613_200307_e3e478"))
    }

    @Test
    func plainTagWithoutNamespace() {
        #expect(HindsightTagRef.parse("user_a") == .plain("user_a"))
    }

    @Test
    func unknownNamespaceIsPlain() {
        #expect(HindsightTagRef.parse("foo:bar") == .plain("foo:bar"))
    }

    @Test
    func emptyValueIsPlain() {
        #expect(HindsightTagRef.parse("session:") == .plain("session:"))
    }

    @Test
    func trimsSurroundingWhitespace() {
        #expect(HindsightTagRef.parse("  session:abc  ") == .session(id: "abc"))
    }

    @Test
    func keepsColonsInValue() {
        // Split on the first colon only; the namespace decides the kind.
        #expect(HindsightTagRef.parse("parent:a:b") == .parentSession(id: "a:b"))
    }
}
