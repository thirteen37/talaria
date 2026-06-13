import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct ProfileSyncHarnessTests {
    // MARK: - Stubs

    /// Path-matching HTTP stub (serves same-path responses in queue order),
    /// mirroring the other Talaria harness tests.
    private final class SyncStubHTTP: DashboardHTTP, @unchecked Sendable {
        struct Response {
            let path: String
            var statusCode: Int = 200
            var body: Data
        }
        private let queue = DispatchQueue(label: "SyncStubHTTP")
        private var responses: [Response]
        private var _recorded: [URLRequest] = []

        init(responses: [Response]) { self.responses = responses }

        var recorded: [URLRequest] { queue.sync { _recorded } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let match: Response? = queue.sync {
                _recorded.append(request)
                guard let index = responses.firstIndex(where: { $0.path == request.url?.path }) else { return nil }
                return responses.remove(at: index)
            }
            guard let url = request.url, let match else { throw URLError(.unsupportedURL) }
            let response = HTTPURLResponse(
                url: url, statusCode: match.statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (match.body, response)
        }
    }

    /// Skills runner returning a default vs named `skills list` table by argv.
    private final class SkillsRunner: HermesAdminRunning, @unchecked Sendable {
        func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
            let argv = command.arguments
            let isWork = argv.contains("work")
            if argv.contains("list") {
                let table = isWork ? Self.workList : Self.defaultList
                return HermesAdminResult(exitCode: 0, stdout: table, stderr: "")
            }
            if argv.contains("check") {
                return HermesAdminResult(exitCode: 0, stdout: "│ weather │ github │ up_to_date │", stderr: "")
            }
            // install / update
            return HermesAdminResult(exitCode: 0, stdout: "Installed: \(argv.last ?? "")", stderr: "")
        }
        func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        static let defaultList = """
        │ weather │ tools │ github │ community │ enabled │
        │ notes │ tools │ github │ community │ enabled │
        """
        static let workList = """
        │ weather │ tools │ github │ community │ enabled │
        """
    }

    private static let catalogJSON = Data(#"""
    {"skills":[
      {"name":"notes","source":"github","identifier":"github/x/notes","trust_level":"community"},
      {"name":"weather","source":"github","identifier":"github/acme/weather","trust_level":"community"}
    ]}
    """#.utf8)

    private static let schemaJSON = Data(#"{"fields":{"model":{"type":"string","category":"Model"}},"category_order":["Model"]}"#.utf8)

    private func client(_ http: SyncStubHTTP) -> DashboardClient {
        DashboardClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: { nil }, http: http)
    }

    /// Builds a harness with file reads stubbed. Pushes go through the window
    /// client scoped to the target (`?profile=<name>`), so they hit `windowHTTP`
    /// — there is no separate scoped dashboard to back.
    private func makeHarness(
        windowHTTP: SyncStubHTTP,
        catalogHTTP: SyncStubHTTP,
        baseRunner: (any HermesAdminRunning)? = SkillsRunner(),
        configReader: @escaping @Sendable (String) async throws -> JSONValue,
        envReader: @escaping @Sendable (String) async throws -> [EnvFileEntry]
    ) -> ProfileSyncHarness {
        let catalog = SkillsHubCatalog(
            indexURL: URL(string: "http://stub.local/index.json")!,
            cacheURL: nil,
            http: catalogHTTP
        )
        let windowClient = client(windowHTTP)
        return ProfileSyncHarness(
            baseRunner: baseRunner,
            windowClient: { windowClient },
            profile: ProfileDirectory.localProfile,
            snapshotTransfer: nil,
            hermesVersion: HermesVersion("0.15.0"),
            catalog: catalog,
            configReader: configReader,
            envReader: envReader
        )
    }

    nonisolated private func defaultVsWorkConfig(_ name: String) -> JSONValue {
        name == "work" ? .object(["model": .string("b")]) : .object(["model": .string("a")])
    }

    nonisolated private func defaultVsWorkEnv(_ name: String) -> [EnvFileEntry] {
        name == "work" ? [] : [EnvFileEntry(key: "OPENAI_API_KEY", value: "sk-longsecretvalue")]
    }

    /// Drift only in a **non-curated** key (`temperature`): hidden by the default
    /// curated filter, so the badge/summary must not count it.
    nonisolated private func nonCuratedConfig(_ name: String) -> JSONValue {
        name == "work" ? .object(["temperature": .number(0.5)]) : .object(["temperature": .number(0.9)])
    }

    // MARK: - Tests

    @Test
    func refreshComputesAllThreeDrifts() async {
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [.init(path: "/api/config/schema", body: Self.schemaJSON)]),
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", body: Self.catalogJSON)]),
            configReader: { self.defaultVsWorkConfig($0) },
            envReader: { self.defaultVsWorkEnv($0) }
        )

        await harness.refresh(namedProfiles: ["work"])

        #expect(harness.skillsDrift["work"]?.items.count == 1) // `notes` missing
        #expect(harness.skillsDrift["work"]?.items.first?.kind == .missing(identifier: "github/x/notes", blocker: nil))
        #expect(harness.configDrift["work"]?.items.contains { $0.dotpath == "model" } == true)
        #expect(harness.envDrift["work"]?.items.first?.key == "OPENAI_API_KEY")
        #expect(harness.catalogError == nil)
        #expect(harness.schemaError == nil)
    }

    @Test
    func schemaFailureDegradesConfigSectionOnly() async {
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [.init(path: "/api/config/schema", statusCode: 404, body: Data())]),
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", body: Self.catalogJSON)]),
            configReader: { self.defaultVsWorkConfig($0) },
            envReader: { self.defaultVsWorkEnv($0) }
        )

        await harness.refresh(namedProfiles: ["work"])

        #expect(harness.schemaError != nil)
        // Config still diffs (curated prefixes are static); skills + env unaffected.
        #expect(harness.configDrift["work"]?.items.isEmpty == false)
        #expect(harness.skillsDrift["work"] != nil)
        #expect(harness.envDrift["work"]?.items.isEmpty == false)
    }

    @Test
    func catalogFailureBlocksSkillInstallsOnly() async {
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [.init(path: "/api/config/schema", body: Self.schemaJSON)]),
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", statusCode: 500, body: Data())]),
            configReader: { self.defaultVsWorkConfig($0) },
            envReader: { self.defaultVsWorkEnv($0) }
        )

        await harness.refresh(namedProfiles: ["work"])

        #expect(harness.catalogError != nil)
        // The missing skill is still listed, just blocked as catalog-unavailable.
        #expect(harness.skillsDrift["work"]?.items.first?.kind == .missing(identifier: nil, blocker: .catalogUnavailable))
        // Config + env are unaffected.
        #expect(harness.configDrift["work"]?.items.isEmpty == false)
        #expect(harness.envDrift["work"]?.items.isEmpty == false)
    }

    @Test
    func perResourceReadErrorLandsInline() async {
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [.init(path: "/api/config/schema", body: Self.schemaJSON)]),
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", body: Self.catalogJSON)]),
            configReader: { name in
                if name == "work" { throw ProfileSyncError.fileReadUnavailable }
                return self.defaultVsWorkConfig(name)
            },
            envReader: { self.defaultVsWorkEnv($0) }
        )

        await harness.refresh(namedProfiles: ["work"])

        #expect(harness.resourceErrors["work"]?[.config] != nil)
        #expect(harness.configDrift["work"] == nil) // config couldn't be computed
        // Skills + env still computed despite the config read failure.
        #expect(harness.skillsDrift["work"] != nil)
        #expect(harness.envDrift["work"]?.items.isEmpty == false)
    }

    @Test
    func syncEverythingPushesConfigAndEnvScopedToTheTarget() async {
        // The window client serves the refresh schema, then the target-scoped
        // pushes (re-GET config, PUT config, PUT env) — all on one HTTP backing
        // since the scoped client is just the window client with `?profile=work`.
        let windowHTTP = SyncStubHTTP(responses: [
            .init(path: "/api/config/schema", body: Self.schemaJSON),
            .init(path: "/api/config", body: Data(#"{"model":"b"}"#.utf8)),
            .init(path: "/api/config", statusCode: 200, body: Data()),
            .init(path: "/api/env", statusCode: 200, body: Data()),
        ])
        let harness = makeHarness(
            windowHTTP: windowHTTP,
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", body: Self.catalogJSON)]),
            configReader: { self.defaultVsWorkConfig($0) },
            envReader: { self.defaultVsWorkEnv($0) }
        )

        await harness.refresh(namedProfiles: ["work"])
        await harness.syncEverything(profile: "work")

        // The config + env writes hit the dashboard scoped to `work` via the query
        // param (no separate process), and the reads/writes reach the right routes.
        let pushes = windowHTTP.recorded.filter { ($0.url?.path ?? "").hasPrefix("/api/config") || $0.url?.path == "/api/env" }
        let methods = pushes.map { "\($0.httpMethod ?? "")\($0.url?.path ?? "")" }
        #expect(methods.contains("GET/api/config"))
        #expect(methods.contains("PUT/api/config"))
        #expect(methods.contains("PUT/api/env"))
        // Every push carries `?profile=work`.
        let writes = windowHTTP.recorded.filter { $0.httpMethod == "PUT" }
        #expect(!writes.isEmpty)
        #expect(writes.allSatisfy { ($0.url?.query ?? "").contains("profile=work") })
        // The post-push refetch bumped the content-drift token so the Skills
        // section's lazy task re-fires (the "Customized" group would otherwise
        // vanish until the user switched profiles and back).
        #expect(harness.skillContentToken > 0)
    }

    @Test
    func nonCuratedPushableConfigCountsOnDesktop() async {
        // The curated filter is iPhone-only; on the desktop/iPad test platform
        // (`Idiom.isPhone == false`) it never applies, so a pushable non-curated
        // diff counts and would sync — matching the full comparison and the
        // section's own "Sync all" (which pushes every pushable row there). This
        // is what closes the gap where "Sync everything" pushed a strict subset of
        // "Sync all (config)" on desktop.
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [.init(path: "/api/config/schema", body: Self.schemaJSON)]),
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", body: Self.catalogJSON)]),
            // No skills/env drift: `work` matches default there, so config is the
            // only axis that can move the count.
            baseRunner: nil,
            configReader: { self.nonCuratedConfig($0) },
            envReader: { _ in [] }
        )

        await harness.refresh(namedProfiles: ["work"])

        #expect(harness.configDrift["work"]?.items.contains { $0.dotpath == "temperature" } == true)
        // Desktop: curated filter off, so the pushable non-curated row counts.
        #expect(harness.curatedConfigOnly == false)
        #expect(harness.syncableConfigCount(for: "work") == 1)
        #expect(harness.differenceCount(for: "work") == 1)
        #expect(harness.canSyncEverything(profile: "work") == true)
    }

    @Test
    func blockedSkillIsNotCountedAsSyncable() async {
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [.init(path: "/api/config/schema", body: Self.schemaJSON)]),
            // Catalog unavailable → the missing `notes` skill can't resolve an
            // install identifier, so it's non-actionable (blocked).
            catalogHTTP: SyncStubHTTP(responses: [.init(path: "/index.json", statusCode: 500, body: Data())]),
            // Identical configs + empty env so skills are the only possible axis.
            configReader: { _ in .object(["model": .string("a")]) },
            envReader: { _ in [] }
        )

        await harness.refresh(namedProfiles: ["work"])

        // The blocked skill exists in the drift…
        #expect(harness.skillsDrift["work"]?.items.contains { !$0.isActionable } == true)
        // …but it can't be synced, so it must not move the count/pill or enable
        // "Sync everything" (whose summary would otherwise say "Nothing to sync").
        #expect(harness.syncableSkillCount(for: "work") == 0)
        #expect(harness.differenceCount(for: "work") == 0)
        #expect(harness.canSyncEverything(profile: "work") == false)
    }

    @Test
    func revealTokenBumpsOnEachRefresh() async {
        let harness = makeHarness(
            windowHTTP: SyncStubHTTP(responses: [
                .init(path: "/api/config/schema", body: Self.schemaJSON),
                .init(path: "/api/config/schema", body: Self.schemaJSON),
            ]),
            catalogHTTP: SyncStubHTTP(responses: [
                .init(path: "/index.json", body: Self.catalogJSON),
                .init(path: "/index.json", body: Self.catalogJSON),
            ]),
            configReader: { self.defaultVsWorkConfig($0) },
            envReader: { self.defaultVsWorkEnv($0) }
        )

        await harness.refresh(namedProfiles: ["work"])
        let first = harness.revealToken
        let firstContent = harness.skillContentToken
        await harness.refresh(namedProfiles: ["work"])
        #expect(harness.revealToken > first)
        // A manual Refresh must also re-fire the Skills content-drift task — the
        // selected profile is unchanged, so the token is the only id that moves.
        #expect(harness.skillContentToken > firstContent)
    }
}
