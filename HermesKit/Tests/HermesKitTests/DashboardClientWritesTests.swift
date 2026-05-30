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

    @Test
    func createProfilePostsNameAndCloneFromDefault() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.createProfile(name: "work", cloneFromDefault: true, noSkills: false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/profiles")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["name"]?.stringValue == "work")
        #expect(json["clone_from_default"]?.boolValue == true)
        #expect(json["no_skills"]?.boolValue == false)
    }

    @Test
    func renameProfilePatchesNewNameToScopedPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles/work", body: Data(#"{"ok":true}"#.utf8))
        ])
        let client = makeClient(http: http)

        try await client.renameProfile(name: "work", newName: "office")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path == "/api/profiles/work")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["new_name"]?.stringValue == "office")
    }

    @Test
    func deleteProfileIssuesDeleteToScopedPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/profiles/work", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.deleteProfile(name: "work")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/profiles/work")
    }

    private func makeClient(http: StubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}
