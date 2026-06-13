import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesSkillContentReaderTests {
    @Test
    func defaultProfilePathIncludesCategoryFolder() {
        #expect(
            HermesSkillContentReader.skillRelativePath(profileName: "default", skillName: "baoyu-article-illustrator", category: "creative")
                == "skills/creative/baoyu-article-illustrator/SKILL.md"
        )
    }

    @Test
    func namedProfilePathIsUnderProfilesDirWithCategory() {
        #expect(
            HermesSkillContentReader.skillRelativePath(profileName: "work", skillName: "weather", category: "tools")
                == "profiles/work/skills/tools/weather/SKILL.md"
        )
    }

    @Test
    func uncategorizedSkillOmitsTheCategoryFolder() {
        #expect(
            HermesSkillContentReader.skillRelativePath(profileName: "default", skillName: "weather", category: nil)
                == "skills/weather/SKILL.md"
        )
        #expect(
            HermesSkillContentReader.skillRelativePath(profileName: "default", skillName: "weather", category: "")
                == "skills/weather/SKILL.md"
        )
    }
}
