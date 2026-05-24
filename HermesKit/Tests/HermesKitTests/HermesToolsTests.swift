import Testing
@testable import HermesKit

@Suite
struct HermesToolsTests {
    @Test
    func parsesCheckboxStyle() {
        let text = """
        [x] Bash    posix
        [x] Read    universal
        [ ] Edit    universal
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ToolRow(name: "Bash", platform: "posix", enabled: true))
        #expect(rows[1] == ToolRow(name: "Read", platform: "universal", enabled: true))
        #expect(rows[2] == ToolRow(name: "Edit", platform: "universal", enabled: false))
    }

    @Test
    func parsesTableStyle() {
        let text = """
        name    platform   enabled
        ------  ---------  -------
        Bash    posix      yes
        Read    universal  yes
        Edit    universal  no
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 3)
        #expect(rows[0] == ToolRow(name: "Bash", platform: "posix", enabled: true))
        #expect(rows[2] == ToolRow(name: "Edit", platform: "universal", enabled: false))
    }

    @Test
    func parsesBareNames() {
        let text = """
        alpha
        beta
        """
        let rows = HermesTools.parse(text)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.enabled })
        #expect(rows.allSatisfy { $0.platform == nil })
    }
}
