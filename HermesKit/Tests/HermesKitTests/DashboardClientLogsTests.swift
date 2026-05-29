import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientLogsTests {
    @Test
    func getLogsDecodesFileAndLines() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/logs", body: try loadFixtureData("logs.json"))
        ])
        let client = makeClient(http: http)

        let response = try await client.getLogs()

        #expect(!response.file.isEmpty)
        #expect(!response.lines.isEmpty)
    }

    @Test
    func getLogsForwardsAllQueryParams() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/logs", body: try loadFixtureData("logs.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.getLogs(
            file: "agent",
            lines: 200,
            level: "WARNING",
            component: "scheduler",
            search: "ECONNREFUSED"
        )

        let request = try #require(http.recordedRequests.first)
        let query = try #require(request.url?.query)
        #expect(query.contains("file=agent"))
        #expect(query.contains("lines=200"))
        #expect(query.contains("level=WARNING"))
        #expect(query.contains("component=scheduler"))
        #expect(query.contains("search=ECONNREFUSED"))
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
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Dashboard")
        )
        return try Data(contentsOf: url)
    }
}
