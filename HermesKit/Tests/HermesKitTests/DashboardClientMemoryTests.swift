import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientMemoryTests {
    @Test
    func getMemoryDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/memory", body: try loadFixtureData("memory.json"))
        ])
        let client = makeClient(http: http)

        let status = try await client.getMemory()

        #expect(status.active == "")
        #expect(status.isBuiltIn)
        #expect(status.providers.map(\.name) == ["hindsight", "sqlite"])
        let hindsight = try #require(status.providers.first { $0.name == "hindsight" })
        #expect(hindsight.configured == true)
        #expect(hindsight.description == "Hindsight long-term memory")
        #expect(status.builtinFiles.memory == 1280)
        #expect(status.builtinFiles.user == 512)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/memory")
    }

    @Test
    func getMemoryReportsExternalProviderActive() async throws {
        let body = Data(#"""
        {"active":"hindsight","providers":[{"name":"hindsight","description":"d","configured":true}],"builtin_files":{"memory":0,"user":0}}
        """#.utf8)
        let http = StubHTTP(responses: [.init(path: "/api/memory", body: body)])
        let client = makeClient(http: http)

        let status = try await client.getMemory()

        #expect(status.active == "hindsight")
        #expect(status.isBuiltIn == false)
    }

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }

    private func loadFixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures/Dashboard"
            )
        )
        return try Data(contentsOf: url)
    }
}
