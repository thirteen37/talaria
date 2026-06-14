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
        let present: Set<String> = ["github", "notion"]
        #expect(HermesSkillsFileStore.inactiveTrackedNames(tracked: tracked, present: present)
                == ["airtable", "ocr-and-documents"])
    }

    @Test func inactiveIsEmptyWhenAllActive() {
        let tracked: Set<String> = ["a", "b"]
        #expect(HermesSkillsFileStore.inactiveTrackedNames(tracked: tracked, present: ["a", "b", "c"]) == [])
    }

    @Test func parsesPresentSkillNamesFromGrepOutput() {
        let out = """
        name: kanban-orchestrator
        name: "quoted-name"
        name: 'single-quoted'
        """
        #expect(HermesSkillsFileStore.parsePresentSkillNames(out)
                == ["kanban-orchestrator", "quoted-name", "single-quoted"])
    }

    @Test func parsePresentSkillNamesIgnoresBlankAndNonNameLinesAndCRLF() {
        let out = "name: a\r\n\r\nnot-a-name-line\r\nname:   b  \r\n"
        #expect(HermesSkillsFileStore.parsePresentSkillNames(out) == ["a", "b"])
    }

    @Test func remoteManifestPathPrependsResolvedHomeForHomeRelativeHermesHome() {
        let path = HermesSkillsFileStore.bundledManifestRemotePath(
            hermesHome: nil, homeDirectory: "/Users/hermes")
        #expect(path == "/Users/hermes/.hermes/skills/.bundled_manifest")
    }

    @Test func remoteManifestPathPassesThroughAbsoluteHermesHome() {
        let path = HermesSkillsFileStore.bundledManifestRemotePath(
            hermesHome: "/opt/hermes", homeDirectory: "/Users/hermes")
        #expect(path == "/opt/hermes/skills/.bundled_manifest")
    }

    @Test func remoteManifestPathFallsBackToTildeWhenHomeUnknown() {
        let path = HermesSkillsFileStore.bundledManifestRemotePath(
            hermesHome: nil, homeDirectory: nil)
        #expect(path == "~/.hermes/skills/.bundled_manifest")
    }

    @Test func remoteManifestPathHandlesTildePrefixedHermesHome() {
        let path = HermesSkillsFileStore.bundledManifestRemotePath(
            hermesHome: "~/.custom-hermes", homeDirectory: "/Users/hermes")
        #expect(path == "/Users/hermes/.custom-hermes/skills/.bundled_manifest")
    }

    @Test func parsesCRLFLineEndings() {
        let text = "airtable:abc123\r\nnotion:def456\r\n"
        #expect(HermesSkillsFileStore.parseBundledManifestNames(text) == ["airtable", "notion"])
    }
}
