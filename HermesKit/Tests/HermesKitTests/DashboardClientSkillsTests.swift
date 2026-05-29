import Foundation
import Testing
@testable import HermesKit

@Suite
struct DashboardClientSkillsTests {
    @Test
    func listSkillsDecodesFixture() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/skills", body: try loadFixtureData("skills-list.json"))
        ])
        let client = makeClient(http: http)

        let skills = try await client.listSkills()

        #expect(skills.count > 0)
        let first = try #require(skills.first)
        #expect(first.name == "apple-notes")
        #expect(first.category == "apple")
        #expect(first.enabled == true)
    }

    @Test
    func toggleSkillSendsPutWithNameAndEnabled() async throws {
        let http = StubHTTP(responses: [
            .init(path: "/api/skills/toggle", body: Data())
        ])
        let client = makeClient(http: http)

        try await client.toggleSkill(name: "apple-notes", enabled: false)

        let request = try #require(http.recordedRequests.first)
        #expect(request.httpMethod == "PUT")
        let body = try #require(request.httpBody ?? request.bodyStreamData())
        let decoded = try JSONDecoder().decode([String: AnyJSON].self, from: body)
        #expect(decoded["name"]?.stringValue == "apple-notes")
        #expect(decoded["enabled"]?.boolValue == false)
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

/// Minimal JSON decoder for tests that need to inspect a body without modeling
/// the full request shape.
enum AnyJSON: Decodable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .other
    }

    var stringValue: String? { if case let .string(v) = self { return v } else { return nil } }
    var intValue: Int? { if case let .int(v) = self { return v } else { return nil } }
    var boolValue: Bool? { if case let .bool(v) = self { return v } else { return nil } }
}

extension URLRequest {
    /// `URLRequest.httpBody` is nil when the body was set via `httpBodyStream`
    /// (which `URLSession` does internally for some methods). For the stub
    /// tests we set `httpBody` directly so this only fires as a fallback.
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
