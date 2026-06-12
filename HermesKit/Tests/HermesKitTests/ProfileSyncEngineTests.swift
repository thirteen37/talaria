import Foundation
import Testing
@testable import HermesKit

@Suite
struct ProfileSyncEngineTests {
    // MARK: - Test runner

    /// Records every command's argv and returns a result chosen by a handler, so
    /// command shape and per-item continuation can be asserted without a real
    /// hermes process.
    private final class ScriptedAdminRunner: HermesAdminRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [[String]] = []
        private let handler: @Sendable ([String]) -> HermesAdminResult

        init(handler: @escaping @Sendable ([String]) -> HermesAdminResult) {
            self.handler = handler
        }

        var commands: [[String]] { lock.withLock { _commands } }

        func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
            lock.withLock { _commands.append(command.arguments) }
            return handler(command.arguments)
        }

        func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// A Rich `skills list` table with a single hub-managed row, so a profile
    /// reports a hub skill and triggers `skills check`.
    private static let hubListTable = """
    │ weather │ tools │ github │ community │ enabled │
    """

    private func okList(_ argv: [String]) -> HermesAdminResult {
        HermesAdminResult(exitCode: 0, stdout: Self.hubListTable, stderr: "")
    }

    // MARK: - Fetch: argv shapes

    @Test
    func skillsListAndCheckUseProfileScopedArgvAndDefaultOmitsFlag() async {
        let base = ScriptedAdminRunner { [self] argv in okList(argv) }
        let engine = ProfileSyncEngine()

        _ = await engine.fetchSnapshots(
            profiles: ["default", "work"],
            runnerProvider: ProfileSyncEngine.scopedRunnerProvider(base: base),
            configReader: { _ in .object([:]) },
            envReader: { _ in [] }
        )

        let commands = base.commands
        #expect(commands.contains(["skills", "list"]))               // default: no -p
        #expect(commands.contains(["-p", "work", "skills", "list"]))
        #expect(commands.contains(["-p", "work", "skills", "check"]))
        // The default profile never runs `skills check`.
        #expect(!commands.contains(["skills", "check"]))
        #expect(!commands.contains(["-p", "default", "skills", "list"]))
    }

    // MARK: - Fetch: failure isolation

    @Test
    func perProfileAndPerResourceFailuresAreIsolated() async {
        let base = ScriptedAdminRunner { [self] argv in okList(argv) }
        let engine = ProfileSyncEngine()

        let result = await engine.fetchSnapshots(
            profiles: ["default", "work"],
            runnerProvider: ProfileSyncEngine.scopedRunnerProvider(base: base),
            configReader: { name in
                if name == "work" { throw HermesConfigReaderError.notFound(path: "x") }
                return .object(["model": .string("a")])
            },
            envReader: { _ in [EnvFileEntry(key: "K", value: "v")] }
        )

        // work: config failed, but skills + env still succeeded.
        let work = result.snapshots["work"]
        #expect(work?.config == nil)
        #expect(work?.skills.isEmpty == false)
        #expect(work?.env != nil)
        #expect(result.failures["work"]?[.config] != nil)
        #expect(result.failures["work"]?[.skills] == nil)

        // default: fully clean — no failures recorded.
        #expect(result.snapshots["default"]?.config != nil)
        #expect(result.failures["default"] == nil)
    }

    // MARK: - Fetch: concurrency cap

    private actor ConcurrencyProbe {
        private(set) var current = 0
        private(set) var maxObserved = 0
        func enter() { current += 1; maxObserved = max(maxObserved, current) }
        func exit() { current -= 1 }
    }

    @Test
    func concurrencyIsCappedAtMaxConcurrent() async {
        let base = ScriptedAdminRunner { [self] argv in okList(argv) }
        let probe = ConcurrencyProbe()
        let engine = ProfileSyncEngine()

        let result = await engine.fetchSnapshots(
            profiles: ["default", "a", "b", "c", "d", "e"],
            runnerProvider: ProfileSyncEngine.scopedRunnerProvider(base: base),
            configReader: { _ in
                await probe.enter()
                try? await Task.sleep(nanoseconds: 15_000_000)
                await probe.exit()
                return .object([:])
            },
            envReader: { _ in [] },
            maxConcurrent: 2
        )

        #expect(result.snapshots.count == 6)
        let observed = await probe.maxObserved
        #expect(observed <= 2)
        #expect(observed >= 2) // proves it genuinely parallelizes up to the cap
    }

    // MARK: - Push: skills

    @Test
    func pushSkillsRunsSequentiallyAndContinuesPastRejection() async {
        // Install of a `bad/*` identifier prints a soft-failure marker (exit 0) →
        // `operationRejected`; the next install succeeds.
        let runner = ScriptedAdminRunner { argv in
            let identifier = argv.last ?? ""
            if identifier.contains("bad") {
                return HermesAdminResult(exitCode: 0, stdout: "Installation blocked: scan", stderr: "")
            }
            return HermesAdminResult(exitCode: 0, stdout: "Installed: \(identifier)", stderr: "")
        }
        let engine = ProfileSyncEngine()

        let outcomes = await engine.pushSkills(
            actions: [
                .install(identifier: "bad/x", name: "badx"),
                .install(identifier: "good/y", name: "goody"),
            ],
            toProfile: "work",
            runnerProvider: ProfileSyncEngine.scopedRunnerProvider(base: runner)
        )

        #expect(outcomes.count == 2)
        #expect(outcomes[0].name == "badx")
        #expect(outcomes[0].succeeded == false)
        #expect(outcomes[1].name == "goody")
        #expect(outcomes[1].succeeded == true)
        // Sequential, in order.
        #expect(runner.commands == [
            ["-p", "work", "skills", "install", "--yes", "--", "bad/x"],
            ["-p", "work", "skills", "install", "--yes", "--", "good/y"],
        ])
    }

    // MARK: - Push: config

    @Test
    func pushConfigReGetsThenPutsMergedWholeDocument() async throws {
        let fresh = Data(#"{"existing":"keep","model":"old"}"#.utf8)
        let http = StubHTTP(responses: [
            .init(path: "/api/config", body: fresh),                // re-GET
            .init(path: "/api/config", statusCode: 200, body: Data()), // PUT
        ])
        let client = DashboardClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: { nil }, http: http)
        let engine = ProfileSyncEngine()

        let outcome = await engine.pushConfig(edits: ["model": .string("new")], client: client)

        #expect(outcome.succeeded)
        let requests = http.recordedRequests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[1].httpMethod == "PUT")

        struct Body: Decodable { let config: JSONValue }
        let body = try JSONDecoder().decode(Body.self, from: try #require(requests[1].httpBody))
        // The edited key changed…
        #expect(ProfileConfigForm.value(at: "model", in: body.config) == .string("new"))
        // …and the untouched key survived the merge.
        #expect(ProfileConfigForm.value(at: "existing", in: body.config) == .string("keep"))
    }

    // MARK: - Push: env

    @Test
    func pushEnvSendsPerKeyBodiesAndContinuesPast4xx() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/env", statusCode: 200, body: Data()),
            .init(path: "/api/env", statusCode: 422, body: Data(#"{"detail":"managed key"}"#.utf8)),
        ])
        let client = DashboardClient(baseURL: URL(string: "http://127.0.0.1:9119")!, token: { nil }, http: http)
        let engine = ProfileSyncEngine()

        let outcomes = await engine.pushEnv(
            items: [(key: "OPENAI_API_KEY", value: "sk-1"), (key: "MANAGED", value: "x")],
            client: client
        )

        #expect(outcomes.count == 2)
        #expect(outcomes[0].key == "OPENAI_API_KEY")
        #expect(outcomes[0].succeeded)
        #expect(outcomes[1].key == "MANAGED")
        #expect(outcomes[1].succeeded == false) // 4xx surfaced, but loop continued

        let requests = http.recordedRequests
        #expect(requests.count == 2)
        struct Body: Decodable { let key: String; let value: String }
        let first = try JSONDecoder().decode(Body.self, from: try #require(requests[0].httpBody))
        #expect(first.key == "OPENAI_API_KEY")
        #expect(first.value == "sk-1")
    }
}
