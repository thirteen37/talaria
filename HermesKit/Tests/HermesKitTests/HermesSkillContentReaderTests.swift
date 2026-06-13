import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesSkillContentReaderTests {
    @Test
    func defaultProfilePathIsHomeRelative() {
        #expect(
            HermesSkillContentReader.skillRelativePath(profileName: "default", skillName: "weather")
                == "skills/weather/SKILL.md"
        )
    }

    @Test
    func namedProfilePathIsUnderProfilesDir() {
        #expect(
            HermesSkillContentReader.skillRelativePath(profileName: "work", skillName: "weather")
                == "profiles/work/skills/weather/SKILL.md"
        )
    }
}
