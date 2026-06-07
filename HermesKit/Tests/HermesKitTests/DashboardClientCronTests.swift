import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientCronTests {
    @Test
    func listCronJobsDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/cron/jobs", body: try loadFixtureData("cron-jobs.json"))
        ])
        let client = makeClient(http: http)

        let jobs = try await client.listCronJobs()

        #expect(jobs.count >= 1)
        let dream = try #require(jobs.first { $0.id == "bb8c626f7f76" })
        #expect(dream.name == "dream")
        #expect(dream.schedule.expr == "0 5 * * *")
        #expect(dream.schedule.kind == "cron")
        #expect(dream.enabled == true)
        #expect(dream.state == "scheduled")
        #expect(dream.profile == "default")

        // A job bound to a non-default profile surfaces that profile's name so
        // the cron table can hot-link it to the Profiles page.
        let dining = try #require(jobs.first { $0.id == "d4d094ba9866" })
        #expect(dining.profile == "dining")
    }

    @Test
    func createCronJobPostsPromptAndSchedule() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/cron/jobs", body: try loadFixtureData("cron-create-response.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.createCronJob(prompt: "Say hi", schedule: "0 9 * * *", name: "morning")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(json["prompt"]?.stringValue == "Say hi")
        #expect(json["schedule"]?.stringValue == "0 9 * * *")
        #expect(json["name"]?.stringValue == "morning")
    }

    @Test
    func deleteCronJobIssuesDeleteToScopedPath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/cron/jobs/abc123", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.deleteCronJob(id: "abc123")

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/cron/jobs/abc123")
    }

    @Test
    func pauseCronJobPostsToPauseSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/cron/jobs/abc/pause", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.pauseCronJob(id: "abc")
        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/cron/jobs/abc/pause")
    }

    @Test
    func resumeCronJobPostsToResumeSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/cron/jobs/abc/resume", body: Data())
        ])
        let client = makeClient(http: http)
        try await client.resumeCronJob(id: "abc")
        #expect(http.recordedRequests.first?.url?.path == "/api/cron/jobs/abc/resume")
    }

    @Test
    func triggerCronJobPostsToTriggerSubpath() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/cron/jobs/abc/trigger", body: Data())
        ])
        let client = makeClient(http: http)
        try await client.triggerCronJob(id: "abc")
        #expect(http.recordedRequests.first?.url?.path == "/api/cron/jobs/abc/trigger")
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
