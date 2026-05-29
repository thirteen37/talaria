import Foundation
import Testing
@testable import HermesKit

@Suite
struct HermesProfilesTests {
    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test
    func parsesRichTable() throws {
        let profiles = HermesProfiles.parse(try fixture("profiles-rich"))
        #expect(profiles.map(\.name) == ["default", "work", "staging"])
        let def = try #require(profiles.first(where: { $0.name == "default" }))
        #expect(def.isDefault == true)
        #expect(def.status == "running")
        let work = try #require(profiles.first(where: { $0.name == "work" }))
        #expect(work.isDefault == false)
        #expect(work.status == "stopped")
        let staging = try #require(profiles.first(where: { $0.name == "staging" }))
        #expect(staging.isDefault == false)
        #expect(staging.status == nil)
    }

    @Test
    func parsesPlainTable() throws {
        let profiles = HermesProfiles.parse(try fixture("profiles-plain"))
        #expect(profiles.map(\.name) == ["default", "work", "staging"])
        #expect(profiles.first(where: { $0.name == "default" })?.isDefault == true)
        #expect(profiles.first(where: { $0.name == "work" })?.status == "stopped")
        #expect(profiles.first(where: { $0.name == "staging" })?.status == nil)
    }

    @Test
    func ensureDefaultInjectsMissingDefaultRow() {
        let parsed = HermesProfiles.parse("work\nstaging")
        #expect(!parsed.contains(where: { $0.name == "default" }))
        let ensured = HermesProfiles.ensureDefault(parsed)
        #expect(ensured.map(\.name) == ["default", "work", "staging"])
        #expect(ensured.first?.isDefault == true)
    }

    @Test
    func ensureDefaultLeavesExistingDefaultUntouched() {
        let parsed = HermesProfiles.parse("default running\nwork")
        let ensured = HermesProfiles.ensureDefault(parsed)
        #expect(ensured.filter { $0.name == "default" }.count == 1)
        #expect(ensured.count == 2)
    }

    @Test
    func ensureSuccessThrowsCommandUnavailableForUnknownCommand() {
        let result = HermesAdminResult(exitCode: 2, stdout: "", stderr: "hermes: no such command 'profile'\n")
        do {
            try HermesProfiles.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesProfilesError {
            if case .commandUnavailable = error {} else {
                #expect(Bool(false), "expected commandUnavailable, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }

    @Test
    func ensureSuccessDoesNotSwallowEnvBinaryNotFound() {
        let result = HermesAdminResult(exitCode: 127, stdout: "", stderr: "env: hermes: No such file or directory\n")
        do {
            try HermesProfiles.ensureSuccess(result)
            #expect(Bool(false), "ensureSuccess should have thrown")
        } catch let error as HermesProfilesError {
            if case .commandFailed = error {} else {
                #expect(Bool(false), "expected commandFailed, got \(error)")
            }
        } catch {
            #expect(Bool(false), "unexpected error type \(error)")
        }
    }
}
