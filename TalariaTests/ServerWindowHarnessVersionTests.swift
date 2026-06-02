import Foundation
import HermesKit
import Testing
@testable import Talaria

/// Covers `ServerWindowHarness.effectiveHermesVersion` — the single source of
/// truth feeding every capability banner. The live dashboard `/api/status`
/// version must win over the profile's cached `hermes --version` probe so a
/// server upgraded after its last probe isn't mis-gated.
@MainActor
@Suite
struct ServerWindowHarnessVersionTests {
    @Test
    func effectiveVersionFallsBackToCachedProbeWhenNoDashboard() {
        let harness = makeHarness(cachedVersion: HermesVersion(major: 0, minor: 14, patch: 0))
        // No dashboard client acquired yet → the cached probe version is used.
        #expect(harness.liveHermesVersion == nil)
        #expect(harness.effectiveHermesVersion == HermesVersion(major: 0, minor: 14, patch: 0))
    }

    @Test
    func refreshLiveVersionOverridesStaleCachedProbe() async {
        // Profile was last probed at 0.14.0, but the running dashboard is 0.15.1.
        let harness = makeHarness(cachedVersion: HermesVersion(major: 0, minor: 14, patch: 0))
        let http = VersionStubHTTP(responses: [
            .init(path: "/api/status", body: Data(#"{"version":"0.15.1","release_date":"2026-06-01"}"#.utf8)),
        ])
        harness.dashboardClient = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )

        await harness.refreshLiveVersion()

        #expect(harness.liveHermesVersion == HermesVersion(major: 0, minor: 15, patch: 1))
        // effectiveHermesVersion now reflects the live server, not the cache.
        #expect(harness.effectiveHermesVersion == HermesVersion(major: 0, minor: 15, patch: 1))
    }

    @Test
    func refreshLiveVersionIsBestEffortOnStatusFailure() async {
        let harness = makeHarness(cachedVersion: HermesVersion(major: 0, minor: 14, patch: 0))
        // Stub has no /api/status response → getStatus throws, caught silently.
        harness.dashboardClient = DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: VersionStubHTTP(responses: [])
        )

        await harness.refreshLiveVersion()

        // Live stays nil; gating falls back to the cached probe rather than erroring.
        #expect(harness.liveHermesVersion == nil)
        #expect(harness.effectiveHermesVersion == HermesVersion(major: 0, minor: 14, patch: 0))
    }

    // MARK: - Helpers

    private func makeHarness(cachedVersion: HermesVersion?) -> ServerWindowHarness {
        let manager = SessionManager { MockACPTransport() }
        let store = SessionsStore(manager: manager, adminRunner: nil)
        let profile = ServerProfile(name: "Test", kind: .ssh, host: "test.local", version: cachedVersion)
        return ServerWindowHarness(store: store, profile: profile)
    }
}

/// Path-matching HTTP stub for the dashboard client (status only here).
private final class VersionStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "VersionStubHTTP")
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let match: Response? = queue.sync {
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
