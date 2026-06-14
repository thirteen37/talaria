import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesSkillsFileStoreManifestTests {
    @Test func parsesV2NameHashLines() {
        let text = """
        airtable:abc123
        ocr-and-documents:def456
        """
        #expect(HermesSkillsFileStore.parseBundledManifestNames(text) == ["airtable", "ocr-and-documents"])
    }

    @Test func parsesV1PlainNamesAndIgnoresBlankAndCommentLines() {
        let text = """
        # Hermes manifest

        plain-name
        another:hash

        """
        #expect(HermesSkillsFileStore.parseBundledManifestNames(text) == ["plain-name", "another"])
    }

    @Test func trimsWhitespaceAroundNames() {
        let text = "  spaced-name : hash \n"
        #expect(HermesSkillsFileStore.parseBundledManifestNames(text) == ["spaced-name"])
    }

    @Test func emptyTextYieldsEmptySet() {
        #expect(HermesSkillsFileStore.parseBundledManifestNames("") == [])
    }

    @Test func inactiveIsTrackedMinusActiveSorted() {
        let tracked: Set<String> = ["airtable", "notion", "ocr-and-documents", "github"]
        let active: Set<String> = ["github", "notion"]
        #expect(HermesSkillsFileStore.inactiveTrackedNames(tracked: tracked, active: active)
                == ["airtable", "ocr-and-documents"])
    }

    @Test func inactiveIsEmptyWhenAllActive() {
        let tracked: Set<String> = ["a", "b"]
        #expect(HermesSkillsFileStore.inactiveTrackedNames(tracked: tracked, active: ["a", "b", "c"]) == [])
    }
}
