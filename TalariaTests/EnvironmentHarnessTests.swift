import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct EnvironmentHarnessTests {
    /// One known provider var so we can prove a file key matching a known name
    /// is dropped (known wins over the file).
    private static let knownEnvJSON = Data(#"""
    {"ANTHROPIC_API_KEY":{"is_set":false,"redacted_value":null,"description":"API key.","url":null,"category":"provider","is_password":true,"tools":[],"advanced":false}}
    """#.utf8)

    @Test
    func refreshAppendsFileOnlyKeysAsCustomAndKnownWins() async throws {
        let http = EnvStubHTTP(responses: [
            .init(path: "/api/env", body: Self.knownEnvJSON)
        ])
        let reader = StubEnvFileReader(result: .success([
            EnvFileEntry(key: "ANTHROPIC_API_KEY", value: "file-value-ignored"), // known → dropped
            EnvFileEntry(key: "MY_CUSTOM", value: "supersecretvalue123"),        // custom → kept
        ]))
        let harness = EnvironmentHarness(client: makeClient(http), fileReader: reader)

        await harness.refresh()

        // The known provider var is untouched — the file did NOT reclassify it.
        let known = harness.vars.filter { $0.name == "ANTHROPIC_API_KEY" }
        #expect(known.count == 1)
        #expect(known.first?.category == "provider")
        // …and its value is NOT un-masked from the file: it's a secret
        // (`is_password`), so the `.env` overlay leaves it reveal-on-demand.
        #expect(known.first?.redactedValue == nil)

        // The file-only key surfaces as a synthesized custom var with its raw
        // value (custom vars are non-secret, so they're shown in full — no
        // password masking).
        let custom = try #require(harness.vars.first { $0.name == "MY_CUSTOM" })
        #expect(custom.category == "custom")
        #expect(custom.isPassword == false)
        #expect(custom.isSet == true)
        #expect(custom.redactedValue == "supersecretvalue123")
        #expect(harness.lastError == nil)
    }

    @Test
    func refreshUnmasksNonSecretKnownVarFromFile() async throws {
        // The dashboard redacts a non-secret var whose value is short (`***`).
        let json = Data(#"""
        {"TELEGRAM_ALLOWED_USERS":{"is_set":true,"redacted_value":"***","description":"Allowed users.","url":null,"category":"messaging","is_password":false,"tools":[],"advanced":false}}
        """#.utf8)
        let http = EnvStubHTTP(responses: [
            .init(path: "/api/env", body: json)
        ])
        let reader = StubEnvFileReader(result: .success([
            EnvFileEntry(key: "TELEGRAM_ALLOWED_USERS", value: "123,456"),
        ]))
        let harness = EnvironmentHarness(client: makeClient(http), fileReader: reader)

        await harness.refresh()

        // The non-secret var is un-masked from the `.env` value, not the
        // dashboard's `***`, so the user sees their own value with no eye toggle.
        let v = try #require(harness.vars.first { $0.name == "TELEGRAM_ALLOWED_USERS" })
        #expect(v.isPassword == false)
        #expect(v.redactedValue == "123,456")
        // It stays a known var (not re-appended as custom).
        #expect(harness.vars.filter { $0.name == "TELEGRAM_ALLOWED_USERS" }.count == 1)
        #expect(v.category == "messaging")
        #expect(harness.lastError == nil)
    }

    @Test
    func refreshKeepsKnownVarsWhenFileReadFails() async throws {
        let http = EnvStubHTTP(responses: [
            .init(path: "/api/env", body: Self.knownEnvJSON)
        ])
        let reader = StubEnvFileReader(result: .failure(EnvFileError.pathUnresolved))
        let harness = EnvironmentHarness(client: makeClient(http), fileReader: reader)

        await harness.refresh()

        // Known vars survive a file-read failure (non-fatal note, not a clobber).
        #expect(harness.vars.contains { $0.name == "ANTHROPIC_API_KEY" })
        #expect(harness.lastError != nil)
    }

    @Test
    func addValidatesNameIssuesPutAndRefreshes() async throws {
        let http = EnvStubHTTP(responses: [
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8)),   // PUT
            .init(path: "/api/env", body: Self.knownEnvJSON),            // refresh GET
        ])
        let reader = StubEnvFileReader(result: .success([]))
        let harness = EnvironmentHarness(client: makeClient(http), fileReader: reader)

        await harness.add(key: "MY_API_BASE", value: "https://example.com")

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/env"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["key"] as? String == "MY_API_BASE")
        #expect(json["value"] as? String == "https://example.com")
        #expect(harness.lastError == nil)
    }

    @Test
    func addRejectsInvalidNameWithoutWriting() async throws {
        let http = EnvStubHTTP(responses: [])
        let reader = StubEnvFileReader(result: .success([]))
        let harness = EnvironmentHarness(client: makeClient(http), fileReader: reader)

        await harness.add(key: "1BAD-NAME", value: "v")

        #expect(harness.lastError != nil)
        #expect(!http.recordedRequests.contains { $0.httpMethod == "PUT" })
    }

    // MARK: - Helpers

    private func makeClient(_ http: EnvStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Canned `EnvFileReading` returning a fixed result (entries or a thrown error).
private struct StubEnvFileReader: EnvFileReading {
    let result: Result<[EnvFileEntry], Error>

    func read() async throws -> [EnvFileEntry] {
        try result.get()
    }
}

/// Path-matching HTTP stub (serves same-path responses in queue order) so a
/// PUT then a refresh GET on `/api/env` resolve deterministically.
private final class EnvStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "EnvStubHTTP")
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
