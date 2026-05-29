import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientWritesTests {
    @Test
    func deleteSessionIssuesDelete() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/sessions/abc-123", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.deleteSession(id: "abc-123")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/sessions/abc-123")
    }

    @Test
    func postHermesUpdatePostsWithNoBody() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/hermes/update", body: Data(#"{"action":"hermes-update","running":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.startHermesUpdate()

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/hermes/update")
    }

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}
