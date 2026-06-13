import Foundation
import Testing
@testable import HermesKit

@Suite
struct ProfileSkillsDriftTests {
    // MARK: - Fixtures

    private func hub(_ name: String, source: String = "github", enabled: Bool = true) -> InstalledHubSkill {
        InstalledHubSkill(name: name, category: nil, source: source, trust: "community", enabled: enabled)
    }

    private func builtin(_ name: String) -> InstalledHubSkill {
        InstalledHubSkill(name: name, category: nil, source: "builtin", trust: "builtin", enabled: true)
    }

    private func local(_ name: String) -> InstalledHubSkill {
        InstalledHubSkill(name: name, category: nil, source: "local", trust: "local", enabled: true)
    }

    private func catalog(_ name: String, source: String, identifier: String) -> HubCatalogSkill {
        HubCatalogSkill(name: name, description: "", source: source, identifier: identifier, trustLevel: "community")
    }

    // MARK: - HubSkillIdentifierIndex cascade

    @Test
    func identifierResolvesWhenInstalledNameIsItselfACatalogIdentifier() {
        // The skills-sh fixture: `hermes skills list` shows the full install
        // identifier as the skill name.
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("foo-bar", source: "skills-sh", identifier: "skills-sh/github/foo-bar"),
        ])
        let installed = hub("skills-sh/github/foo-bar", source: "skills-sh")
        #expect(index.identifier(for: installed) == "skills-sh/github/foo-bar")
    }

    @Test
    func identifierResolvesByExactNameAndSource() {
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("weather", source: "github", identifier: "github/acme/weather"),
            catalog("weather", source: "official", identifier: "official/tools/weather"),
        ])
        let installed = hub("weather", source: "GitHub") // case-insensitive
        #expect(index.identifier(for: installed) == "github/acme/weather")
    }

    @Test
    func identifierResolvesByUniqueNameWhenSourceDoesNotMatch() {
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("translate", source: "official", identifier: "official/lang/translate"),
        ])
        // Source differs from the catalog entry, but the name is unique.
        let installed = hub("translate", source: "github")
        #expect(index.identifier(for: installed) == "official/lang/translate")
    }

    @Test
    func sourcedMatchWinsOverABareNameIdentifierFromAnotherSource() {
        // The Nous index has clawhub skills whose identifier IS a bare name. An
        // *official* skill named "1password" must resolve to its own
        // "official/security/1password", not the clawhub bare-name "1password".
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("1password", source: "clawhub", identifier: "1password"),
            catalog("1password", source: "official", identifier: "official/security/1password"),
        ])
        let installed = hub("1password", source: "official")
        #expect(index.identifier(for: installed) == "official/security/1password")
    }

    @Test
    func identifierIsNilWhenNameIsAmbiguousAcrossSources() {
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("common", source: "github", identifier: "github/a/common"),
            catalog("common", source: "clawhub", identifier: "clawhub/b/common"),
        ])
        // Name collides and the source doesn't disambiguate.
        let installed = hub("common", source: "lobehub")
        #expect(index.identifier(for: installed) == nil)
    }

    // MARK: - Missing skills

    @Test
    func missingHubSkillCarriesItsInstallIdentifier() {
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("weather", source: "github", identifier: "github/acme/weather"),
        ])
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("weather", source: "github")],
            profileSkills: [],
            updateStatuses: [],
            index: index
        )
        #expect(drift.items.count == 1)
        let item = drift.items[0]
        #expect(item.name == "weather")
        #expect(item.kind == .missing(identifier: "github/acme/weather", blocker: nil))
        #expect(item.installIdentifier == "github/acme/weather")
        #expect(item.isActionable)
    }

    @Test
    func missingHubSkillWithNoCatalogMatchIsBlockedAsIdentifierNotFound() {
        let index = HubSkillIdentifierIndex(catalog: [])
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("mystery", source: "github")],
            profileSkills: [],
            updateStatuses: [],
            index: index
        )
        let item = try! #require(drift.items.first)
        #expect(item.kind == .missing(identifier: nil, blocker: .identifierNotFound))
        #expect(!item.isActionable)
        #expect(item.installIdentifier == nil)
    }

    @Test
    func missingHubSkillWithNilIndexIsBlockedAsCatalogUnavailable() {
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("weather", source: "github")],
            profileSkills: [],
            updateStatuses: [],
            index: nil
        )
        let item = try! #require(drift.items.first)
        #expect(item.kind == .missing(identifier: nil, blocker: .catalogUnavailable))
        #expect(!item.isActionable)
    }

    // MARK: - Candidate filtering

    @Test
    func builtinAndLocalDefaultSkillsAreNeverCandidates() {
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [builtin("dogfood"), local("cmux")],
            profileSkills: [],
            updateStatuses: [],
            index: HubSkillIdentifierIndex(catalog: [])
        )
        #expect(drift.items.isEmpty)
        #expect(drift.isInSync)
    }

    @Test
    func nameCollidingLocalSkillCountsAsPresentAndBlocksInstall() {
        // Default has a hub `notes`; the named profile has a *local* `notes`.
        // Never clobber: treat as present, not missing, and not outdated.
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("notes", source: "github")],
            profileSkills: [local("notes")],
            updateStatuses: [],
            index: HubSkillIdentifierIndex(catalog: [
                catalog("notes", source: "github", identifier: "github/x/notes"),
            ])
        )
        #expect(drift.items.isEmpty)
        #expect(drift.isInSync)
    }

    // MARK: - Outdated

    @Test
    func presentHubSkillWithUpdateAvailableIsOutdated() {
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("weather", source: "github")],
            profileSkills: [hub("weather", source: "github")],
            updateStatuses: [SkillUpdateStatus(name: "weather", source: "github", status: "update_available")],
            index: HubSkillIdentifierIndex(catalog: [])
        )
        #expect(drift.items.count == 1)
        #expect(drift.items[0].kind == .outdated)
        #expect(drift.items[0].isActionable)
        #expect(drift.outdatedCount == 1)
        #expect(drift.missingCount == 0)
    }

    @Test
    func presentHubSkillUpToDateIsInSync() {
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("weather", source: "github", enabled: true)],
            profileSkills: [hub("weather", source: "github", enabled: false)], // enabled ignored
            updateStatuses: [SkillUpdateStatus(name: "weather", source: "github", status: "up_to_date")],
            index: HubSkillIdentifierIndex(catalog: [])
        )
        #expect(drift.isInSync)
    }

    // MARK: - Extras & locals

    @Test
    func hubSkillsOnlyInNamedProfileAreExtras() {
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("weather", source: "github")],
            profileSkills: [hub("weather", source: "github"), hub("crypto", source: "clawhub")],
            updateStatuses: [],
            index: HubSkillIdentifierIndex(catalog: [])
        )
        #expect(drift.isInSync) // extras don't make it out of sync
        #expect(drift.extras.map(\.name) == ["crypto"])
    }

    @Test
    func unsyncableLocalSkillsAreDefaultLocalSkills() {
        let result = ProfileSkillsDriftPlanner.unsyncableLocalSkills(
            defaultSkills: [hub("weather", source: "github"), local("cmux"), builtin("dogfood")]
        )
        #expect(result.map(\.name) == ["cmux"])
    }

    // MARK: - Ordering

    @Test
    func itemsFollowDefaultProfileOrder() {
        let index = HubSkillIdentifierIndex(catalog: [
            catalog("alpha", source: "github", identifier: "github/x/alpha"),
            catalog("zeta", source: "github", identifier: "github/x/zeta"),
        ])
        let drift = ProfileSkillsDriftPlanner.drift(
            profileName: "work",
            defaultSkills: [hub("zeta", source: "github"), hub("alpha", source: "github")],
            profileSkills: [],
            updateStatuses: [],
            index: index
        )
        #expect(drift.items.map(\.name) == ["zeta", "alpha"])
    }
}
