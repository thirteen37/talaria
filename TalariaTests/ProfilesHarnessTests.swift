import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct ProfilesHarnessTests {
    /// `default` (clean name, structured flag) plus a non-default row — the
    /// dashboard shape, never the decorated CLI `profile list` table.
    private static let profilesJSON = Data(#"""
    {"profiles":[
      {"name":"default","is_default":true,"model":"anthropic/claude-sonnet-4.6"},
      {"name":"work","is_default":false,"model":null}
    ]}
    """#.utf8)

    private static let okJSON = Data(#"{"ok":true}"#.utf8)

    @Test
    func refreshPopulatesCleanDashboardNames() async throws {
        let http = ProfilesStubHTTP(responses: [
            .init(path: "/api/profiles", body: Self.profilesJSON),
        ])
        let harness = ProfilesHarness(client: makeClient(http), runner: nil, profile: ProfileDirectory.localProfile, onProfilesChanged: {})

        await harness.refresh()

        #expect(harness.profiles.map(\.name) == ["default", "work"])
        #expect(harness.profiles.filter(\.isDefault).map(\.name) == ["default"])
        #expect(harness.lastError == nil)
    }

    @Test
    func refreshSurfacesErrorAndDoesNotFallBackOnFailure() async throws {
        // The dashboard route errors. There is no CLI fallback: the harness
        // surfaces the error rather than leaking CLI-parsed `◆default` names.
        let http = ProfilesStubHTTP(responses: [
            .init(path: "/api/profiles", statusCode: 500, body: Data("boom".utf8)),
        ])
        let banners = BannerCenter()
        let harness = ProfilesHarness(client: makeClient(http), runner: nil, profile: ProfileDirectory.localProfile, onProfilesChanged: {})
        harness.banners = banners

        await harness.refresh()

        // No silent degrade to a `default`-only (or CLI-parsed) list.
        #expect(harness.profiles.isEmpty)
        #expect(harness.lastError != nil)
        // The error is routed to the top-of-window strip keyed by the surface id.
        #expect(banners.banners.contains { $0.key == "profiles" && $0.severity == .error })
    }

    @Test
    func canCloneOnlyForDefaultRow() async throws {
        let http = ProfilesStubHTTP(responses: [
            .init(path: "/api/profiles", body: Self.profilesJSON),
        ])
        let harness = ProfilesHarness(client: makeClient(http), runner: nil, profile: ProfileDirectory.localProfile, onProfilesChanged: {})

        await harness.refresh()

        // Nothing selected → cannot clone.
        #expect(harness.canClone == false)
        // The default row is the only valid clone source (dashboard clones from
        // default only).
        harness.selectionID = "default"
        #expect(harness.canClone == true)
        // A non-default row cannot be cloned.
        harness.selectionID = "work"
        #expect(harness.canClone == false)
    }

    // MARK: - Mutations (dashboard-only write paths)

    @Test
    func cloneIssuesPostWithCloneFromDefault() async throws {
        let http = ProfilesStubHTTP(responses: [
            .init(path: "/api/profiles", body: Self.okJSON),       // POST
            .init(path: "/api/profiles", body: Self.profilesJSON), // refresh GET
        ])
        let harness = ProfilesHarness(client: makeClient(http), runner: nil, profile: ProfileDirectory.localProfile, onProfilesChanged: {})

        await harness.clone(newName: "newprofile")

        let post = try #require(http.recordedRequests.first {
            $0.httpMethod == "POST" && $0.url?.path == "/api/profiles"
        })
        let body = try #require(post.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["name"] as? String == "newprofile")
        // The whole point of dashboard-only clone gating: always seed from default.
        #expect(json["clone_from_default"] as? Bool == true)
        #expect(harness.lastError == nil)
    }

    @Test
    func renameIssuesPatchToProfilePath() async throws {
        let http = ProfilesStubHTTP(responses: [
            .init(path: "/api/profiles/work", body: Self.okJSON),  // PATCH
            .init(path: "/api/profiles", body: Self.profilesJSON), // refresh GET
        ])
        let harness = ProfilesHarness(client: makeClient(http), runner: nil, profile: ProfileDirectory.localProfile, onProfilesChanged: {})

        await harness.rename(from: "work", to: "office")

        let patch = try #require(http.recordedRequests.first {
            $0.httpMethod == "PATCH" && $0.url?.path == "/api/profiles/work"
        })
        let body = try #require(patch.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["new_name"] as? String == "office")
        #expect(harness.lastError == nil)
    }

    @Test
    func deleteIssuesDeleteToProfilePath() async throws {
        let http = ProfilesStubHTTP(responses: [
            .init(path: "/api/profiles/work", body: Self.okJSON),  // DELETE
            .init(path: "/api/profiles", body: Self.profilesJSON), // refresh GET
        ])
        let harness = ProfilesHarness(client: makeClient(http), runner: nil, profile: ProfileDirectory.localProfile, onProfilesChanged: {})

        await harness.delete(name: "work")

        let request = try #require(http.recordedRequests.first {
            $0.httpMethod == "DELETE" && $0.url?.path == "/api/profiles/work"
        })
        #expect(request.httpMethod == "DELETE")
        #expect(harness.lastError == nil)
    }

    // MARK: - Helpers

    private func makeClient(_ http: ProfilesStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Path-matching HTTP stub (serves same-path responses in queue order).
private final class ProfilesStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "ProfilesStubHTTP")
    private var responses: [Response]
    private var _recordedRequests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var recordedRequests: [URLRequest] { queue.sync { _recordedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let match: Response? = queue.sync {
            _recordedRequests.append(request)
            guard let index = responses.firstIndex(where: { $0.path == request.url?.path }) else {
                return nil
            }
            return responses.remove(at: index)
        }
        guard let url = request.url, let match else {
            throw URLError(.unsupportedURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: match.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (match.body, response)
    }
}
