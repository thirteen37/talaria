import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardTokenExtractorTests {
    @Test
    func extractsTokenFromRealSPAResponse() throws {
        let html = try loadFixture("spa-index.html")
        let token = DashboardTokenExtractor.extract(fromHTML: html)
        #expect(token == "ntHr7-4LVSWHFi7jKLvXDMYM2DVrN5kcUhwKY_KsIcM")
    }

    @Test
    func returnsNilWhenMarkerAbsent() {
        let html = "<html><head></head><body>no token here</body></html>"
        #expect(DashboardTokenExtractor.extract(fromHTML: html) == nil)
    }

    @Test
    func returnsNilWhenTokenValueEmpty() {
        let html = #"<script>window.__HERMES_SESSION_TOKEN__="";</script>"#
        #expect(DashboardTokenExtractor.extract(fromHTML: html) == nil)
    }

    private func loadFixture(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Dashboard")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
