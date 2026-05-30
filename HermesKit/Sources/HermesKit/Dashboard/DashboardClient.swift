import Foundation

/// HTTP plumbing seam — the test bundle plugs in a stub, production uses
/// `URLSession.shared`. Kept as a protocol (rather than taking a closure)
/// because the same shape will host the future iOS NIO-based transport
/// once we plumb dashboard mode over a pure-Swift HTTP/2 client.
public protocol DashboardHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DashboardHTTP {}

public enum DashboardClientError: Error, Equatable, Sendable, LocalizedError {
    /// 401 — the cached session token was rejected. Callers refresh by
    /// re-scraping `GET /` via `DashboardTokenExtractor` and retry.
    case unauthorized
    /// Any non-2xx status that isn't 401. `body` is included verbatim for
    /// surfacing in the UI / Doctor probe rows.
    case http(statusCode: Int, body: String)
    /// Response body wasn't shaped like the route we expected. Likely an
    /// upstream Hermes change — caller flips the per-route capability flag.
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Dashboard rejected the session token."
        case let .http(code, body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Dashboard returned HTTP \(code)."
                : "Dashboard returned HTTP \(code): \(trimmed)"
        case let .decoding(message):
            return "Dashboard response wasn't in the expected shape: \(message)"
        }
    }
}

public struct DashboardStatus: Codable, Equatable, Sendable {
    public let version: String
    public let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case version
        case releaseDate = "release_date"
    }
}

public struct DashboardSessionSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let startedAt: Double?
    public let endedAt: Double?
    public let source: String?

    enum CodingKeys: String, CodingKey {
        case id, title, source
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

public struct DashboardSessionsResponse: Codable, Equatable, Sendable {
    public let sessions: [DashboardSessionSummary]
}

public struct DashboardSessionSearchResult: Codable, Equatable, Sendable {
    public let sessionId: String
    public let snippet: String?
    public let role: String?
    public let sessionStarted: Double?

    public var displaySnippet: String? {
        snippet?
            .replacingOccurrences(of: ">>>", with: "")
            .replacingOccurrences(of: "<<<", with: "")
    }

    enum CodingKeys: String, CodingKey {
        case snippet, role
        case sessionId = "session_id"
        case sessionStarted = "session_started"
    }
}

public struct DashboardSessionsSearchResponse: Codable, Equatable, Sendable {
    public let results: [DashboardSessionSearchResult]
}

public struct DashboardActionStatus: Codable, Equatable, Sendable {
    public let name: String
    public let running: Bool
    public let exitCode: Int?
    public let pid: Int?
    public let lines: [String]

    enum CodingKeys: String, CodingKey {
        case name, running, pid, lines
        case exitCode = "exit_code"
    }
}

public struct DashboardSkill: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String?
    public let category: String?
    public let enabled: Bool

    public var id: String { name }
}

public struct DashboardCronSchedule: Codable, Equatable, Sendable {
    /// `"cron"` or `"interval"`. Drives which of `expr` / `minutes` is set.
    public let kind: String
    /// Crontab expression when `kind == "cron"`. Nil for interval jobs.
    public let expr: String?
    /// Period in minutes when `kind == "interval"`. Nil for cron jobs.
    public let minutes: Int?
    /// Human-readable rendering of the schedule. Always present.
    public let display: String?
}

public struct DashboardCronJob: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let prompt: String
    public let schedule: DashboardCronSchedule
    public let enabled: Bool
    public let state: String?
    public let lastRunAt: String?
    public let nextRunAt: String?
    public let lastStatus: String?
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, schedule, enabled, state
        case lastRunAt = "last_run_at"
        case nextRunAt = "next_run_at"
        case lastStatus = "last_status"
        case lastError = "last_error"
    }
}

public struct DashboardLogsResponse: Codable, Equatable, Sendable {
    public let file: String
    public let lines: [String]
}

/// One profile from `GET /api/profiles`. The dashboard reports clean names and a
/// structured `is_default` flag, so the editor's profile picker uses this rather
/// than parsing `hermes profile list`'s decorated CLI table (whose default
/// marker glyph would otherwise leak into the name).
public struct DashboardProfile: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let isDefault: Bool
    public let model: String?
    public let provider: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, model, provider
        case isDefault = "is_default"
    }
}

public struct DashboardClient: Sendable {
    public let baseURL: URL
    private let token: @Sendable () -> String?
    private let onUnauthorized: @Sendable () async -> Void
    private let http: any DashboardHTTP
    private static let queryComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    public init(
        baseURL: URL,
        token: @escaping @Sendable () -> String?,
        onUnauthorized: @escaping @Sendable () async -> Void = {},
        http: any DashboardHTTP = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.token = token
        self.onUnauthorized = onUnauthorized
        self.http = http
    }

    public func getStatus() async throws -> DashboardStatus {
        try await get(path: "/api/status")
    }

    public func listSessions(limit: Int? = nil, offset: Int? = nil) async throws -> DashboardSessionsResponse {
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        return try await get(path: "/api/sessions", queryItems: items)
    }

    public func searchSessions(query: String, limit: Int? = nil) async throws -> DashboardSessionsSearchResponse {
        var items: [URLQueryItem] = [URLQueryItem(name: "q", value: query)]
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(path: "/api/sessions/search", queryItems: items)
    }

    public func getUpdateActionStatus() async throws -> DashboardActionStatus {
        try await get(path: "/api/actions/hermes-update/status")
    }

    public func deleteSession(id: String) async throws {
        try await sendNoContent(method: "DELETE", path: "/api/sessions/\(id)")
    }

    public func startHermesUpdate() async throws {
        try await sendNoContent(method: "POST", path: "/api/hermes/update")
    }

    // MARK: - Skills

    public func listSkills() async throws -> [DashboardSkill] {
        try await get(path: "/api/skills")
    }

    public func toggleSkill(name: String, enabled: Bool) async throws {
        let body = SkillToggleBody(name: name, enabled: enabled)
        try await sendNoContent(method: "PUT", path: "/api/skills/toggle", body: body)
    }

    private struct SkillToggleBody: Encodable {
        let name: String
        let enabled: Bool
    }

    // MARK: - Cron

    public func listCronJobs() async throws -> [DashboardCronJob] {
        try await get(path: "/api/cron/jobs")
    }

    public func createCronJob(
        prompt: String,
        schedule: String,
        name: String? = nil,
        deliver: String? = nil
    ) async throws -> DashboardCronJob {
        let body = CronJobCreateBody(prompt: prompt, schedule: schedule, name: name, deliver: deliver)
        return try await sendDecoding(method: "POST", path: "/api/cron/jobs", body: body)
    }

    public func deleteCronJob(id: String) async throws {
        try await sendNoContent(method: "DELETE", path: "/api/cron/jobs/\(id)")
    }

    /// Free-form patch — the dashboard's `CronJobUpdate` wraps an `updates`
    /// dict and accepts whatever fields the caller wants to overwrite
    /// (`prompt`, `schedule`, …). Strings only for now; richer overrides
    /// can be added when their typed shape stabilizes upstream.
    public func updateCronJob(id: String, updates: [String: String]) async throws {
        let body = CronJobUpdateBody(updates: updates)
        try await sendNoContent(method: "PUT", path: "/api/cron/jobs/\(id)", body: body)
    }

    private struct CronJobUpdateBody: Encodable {
        let updates: [String: String]
    }

    public func pauseCronJob(id: String) async throws {
        try await sendNoContent(method: "POST", path: "/api/cron/jobs/\(id)/pause")
    }

    public func resumeCronJob(id: String) async throws {
        try await sendNoContent(method: "POST", path: "/api/cron/jobs/\(id)/resume")
    }

    public func triggerCronJob(id: String) async throws {
        try await sendNoContent(method: "POST", path: "/api/cron/jobs/\(id)/trigger")
    }

    private struct CronJobCreateBody: Encodable {
        let prompt: String
        let schedule: String
        let name: String?
        let deliver: String?
    }

    // MARK: - Profiles

    /// Lists the Hermes profiles known to the dashboard host. Profile-agnostic
    /// (scans the profiles directory), so the window's default dashboard client
    /// can enumerate every profile.
    public func listProfiles() async throws -> [DashboardProfile] {
        let response: ProfilesResponse = try await get(path: "/api/profiles")
        return response.profiles
    }

    private struct ProfilesResponse: Decodable {
        let profiles: [DashboardProfile]
    }

    // MARK: - Config

    /// Profile-agnostic field schema driving the structured editor. Public
    /// route (no token required), but the token is still sent when available.
    /// Parsed via Yams rather than the generic `Decodable` path so the field
    /// order the dashboard emits is preserved — see ``DashboardConfigSchema``.
    public func getConfigSchema() async throws -> DashboardConfigSchema {
        let data = try await sendRawData(method: "GET", path: "/api/config/schema")
        return try DashboardConfigSchema(data: data)
    }

    /// Current config for the dashboard process's profile, returned verbatim as
    /// a `JSONValue` so arbitrary keys round-trip losslessly (the structured
    /// form and the non-destructive merge both operate on this object).
    public func getConfig() async throws -> JSONValue {
        try await get(path: "/api/config")
    }

    /// Writes the whole config atomically. The dashboard's `ConfigUpdate` model
    /// wraps the object under a `config` key.
    public func updateConfig(_ config: JSONValue) async throws {
        let body = ConfigUpdateBody(config: config)
        try await sendNoContent(method: "PUT", path: "/api/config", body: body)
    }

    private struct ConfigUpdateBody: Encodable {
        let config: JSONValue
    }

    // MARK: - Soul

    public func getSoul() async throws -> String {
        let response: SoulResponse = try await get(path: "/api/soul")
        return response.content
    }

    public func updateSoul(_ content: String) async throws {
        try await sendNoContent(method: "PUT", path: "/api/soul", body: SoulUpdateBody(content: content))
    }

    private struct SoulResponse: Decodable {
        let content: String
    }

    private struct SoulUpdateBody: Encodable {
        let content: String
    }

    // MARK: - Logs

    public func getLogs(
        file: String? = nil,
        lines: Int? = nil,
        level: String? = nil,
        component: String? = nil,
        search: String? = nil
    ) async throws -> DashboardLogsResponse {
        var items: [URLQueryItem] = []
        if let file { items.append(URLQueryItem(name: "file", value: file)) }
        if let lines { items.append(URLQueryItem(name: "lines", value: String(lines))) }
        if let level { items.append(URLQueryItem(name: "level", value: level)) }
        if let component { items.append(URLQueryItem(name: "component", value: component)) }
        if let search { items.append(URLQueryItem(name: "search", value: search)) }
        return try await get(path: "/api/logs", queryItems: items)
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        try await sendDecoding(method: "GET", path: path, queryItems: queryItems)
    }

    private func sendDecoding<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Encodable? = nil
    ) async throws -> T {
        do {
            return try await sendOnce(method: method, path: path, queryItems: queryItems, body: body)
        } catch DashboardClientError.unauthorized {
            await onUnauthorized()
            return try await sendOnce(method: method, path: path, queryItems: queryItems, body: body)
        }
    }

    private func sendNoContent(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Encodable? = nil
    ) async throws {
        do {
            try await sendOnceVoid(method: method, path: path, queryItems: queryItems, body: body)
        } catch DashboardClientError.unauthorized {
            await onUnauthorized()
            try await sendOnceVoid(method: method, path: path, queryItems: queryItems, body: body)
        }
    }

    /// Like ``sendDecoding`` but returns the raw response body. Used by routes
    /// whose payload needs order-preserving parsing (the config schema) rather
    /// than Foundation's key-hashing `JSONDecoder`.
    private func sendRawData(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Encodable? = nil
    ) async throws -> Data {
        do {
            let (data, _) = try await dispatch(method: method, path: path, queryItems: queryItems, body: body)
            return data
        } catch DashboardClientError.unauthorized {
            await onUnauthorized()
            let (data, _) = try await dispatch(method: method, path: path, queryItems: queryItems, body: body)
            return data
        }
    }

    private func sendOnce<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Encodable?
    ) async throws -> T {
        let (data, _) = try await dispatch(method: method, path: path, queryItems: queryItems, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DashboardClientError.decoding("\(T.self): \(error.localizedDescription)")
        }
    }

    private func sendOnceVoid(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Encodable?
    ) async throws {
        _ = try await dispatch(method: method, path: path, queryItems: queryItems, body: body)
    }

    private func dispatch(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: Encodable?
    ) async throws -> (Data, URLResponse) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !queryItems.isEmpty {
            components.percentEncodedQuery = Self.percentEncodedQuery(for: queryItems)
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let token = token() {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, response) = try await http.data(for: request)
        try check(response: response, data: data)
        return (data, response)
    }

    private static func percentEncodedQuery(for items: [URLQueryItem]) -> String {
        items
            .map { item in
                let name = percentEncodeQueryComponent(item.name)
                guard let value = item.value else { return name }
                return "\(name)=\(percentEncodeQueryComponent(value))"
            }
            .joined(separator: "&")
    }

    private static func percentEncodeQueryComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowed) ?? value
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw DashboardClientError.unauthorized
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DashboardClientError.http(statusCode: http.statusCode, body: body)
        }
    }
}

/// Erases the concrete type of an `Encodable` so `dispatch` can take an
/// untyped body parameter without a generic argument. Swift's
/// `Encodable.encode(to:)` is what JSONEncoder actually calls, so this
/// box is a one-liner.
private struct AnyEncodable: Encodable {
    let wrapped: Encodable
    init(_ wrapped: Encodable) { self.wrapped = wrapped }
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}
