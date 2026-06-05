import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientAnalyticsTests {
    // MARK: - Usage

    @Test
    func getUsageAnalyticsDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/analytics/usage", body: try loadFixtureData("analytics-usage.json"))
        ])
        let client = makeClient(http: http)

        let usage = try await client.getUsageAnalytics(days: 30)

        #expect(usage.periodDays == 30)
        #expect(usage.daily.count == 2)
        let first = try #require(usage.daily.first)
        #expect(first.day == "2026-05-30")
        #expect(first.inputTokens == 120000)
        #expect(first.outputTokens == 8000)
        #expect(first.cacheReadTokens == 40000)
        #expect(first.reasoningTokens == 2000)
        #expect(first.estimatedCost == 1.23)
        #expect(first.actualCost == 1.1)
        #expect(first.sessions == 4)
        #expect(first.apiCalls == 37)
        #expect(first.totalTokens == 128000)
        // A null SUM field decodes to nil (the second day's reasoning_tokens).
        #expect(usage.daily[1].reasoningTokens == nil)

        #expect(usage.byModel.count == 2)
        let opus = try #require(usage.byModel.first { $0.model == "claude-opus-4-8" })
        #expect(opus.inputTokens == 150000)
        #expect(opus.sessions == 5)
        #expect(opus.apiCalls == 44)

        #expect(usage.totals.totalInput == 170000)
        #expect(usage.totals.totalOutput == 11000)
        #expect(usage.totals.totalEstimatedCost == 1.73)
        #expect(usage.totals.totalActualCost == 1.1)
        #expect(usage.totals.totalSessions == 6)
        #expect(usage.totals.totalApiCalls == 49)
        #expect(usage.totals.totalTokens == 181000)
    }

    @Test
    func getUsageAnalyticsSendsDaysQuery() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/analytics/usage", body: try loadFixtureData("analytics-usage.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.getUsageAnalytics(days: 90)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/analytics/usage")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "days" }?.value == "90")
    }

    /// A fresh install (or an empty `days` window) returns empty arrays and a
    /// totals row whose SUM fields are `null` while COUNT/COALESCE fields are 0.
    /// Decoding must not throw, and the coalescing accessors must report 0.
    @Test
    func getUsageAnalyticsDecodesEmptyHistory() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/analytics/usage", body: try loadFixtureData("analytics-usage-empty.json"))
        ])
        let client = makeClient(http: http)

        let usage = try await client.getUsageAnalytics(days: 7)

        #expect(usage.periodDays == 7)
        #expect(usage.daily.isEmpty)
        #expect(usage.byModel.isEmpty)
        #expect(usage.totals.totalInput == nil)
        #expect(usage.totals.totalApiCalls == nil)
        #expect(usage.totals.totalSessions == 0)
        #expect(usage.totals.totalEstimatedCost == 0)
        // Coalescing accessor turns the null SUMs into 0.
        #expect(usage.totals.totalTokens == 0)
    }

    // MARK: - Models

    @Test
    func getModelAnalyticsDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/analytics/models", body: try loadFixtureData("analytics-models.json"))
        ])
        let client = makeClient(http: http)

        let analytics = try await client.getModelAnalytics(days: 30)

        #expect(analytics.periodDays == 30)
        #expect(analytics.totals.distinctModels == 2)
        #expect(analytics.models.count == 2)

        let opus = try #require(analytics.models.first { $0.model == "claude-opus-4-8" })
        #expect(opus.provider == "anthropic")
        #expect(opus.cacheReadTokens == 50000)
        #expect(opus.toolCalls == 18)
        #expect(opus.lastUsedAt == 1748563200.0)
        #expect(opus.avgTokensPerSession == 32000.0)
        #expect(opus.capabilities?.contextWindow == 200000)
        #expect(opus.capabilities?.supportsVision == true)
        #expect(opus.capabilities?.modelFamily == "claude")

        // Empty capabilities object + null token fields decode cleanly.
        let haiku = try #require(analytics.models.first { $0.model == "claude-haiku-4-5" })
        #expect(haiku.cacheReadTokens == nil)
        #expect(haiku.toolCalls == nil)
        #expect(haiku.capabilities?.contextWindow == nil)
    }

    @Test
    func getModelAnalyticsSendsDaysQuery() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/analytics/models", body: try loadFixtureData("analytics-models.json"))
        ])
        let client = makeClient(http: http)

        _ = try await client.getModelAnalytics(days: 7)

        let request = try #require(http.recordedRequests.first)
        #expect(request.url?.path == "/api/analytics/models")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "days" }?.value == "7")
    }

    // MARK: - Helpers

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
