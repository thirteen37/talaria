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

/// One messaging platform's connection state inside `gateway_platforms`.
/// `state` is a free-form string from Hermes (`connected`, `connecting`,
/// `error`, …); `errorCode` / `errorMessage` are populated when a platform
/// fails to connect.
public struct GatewayPlatform: Codable, Equatable, Sendable {
    public let state: String?
    public let errorCode: String?
    public let errorMessage: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case state
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case updatedAt = "updated_at"
    }
}

public struct DashboardStatus: Codable, Equatable, Sendable {
    public let version: String
    public let releaseDate: String?
    /// Gateway fields are optional so this still decodes against a pre-gateway
    /// dashboard payload, and callers that read only `version` keep working
    /// unchanged. The dashboard's
    /// `gateway_state` is one of `running` / `stopped` / `startup_failed` /
    /// `draining` / null — it does **not** report install state (that's a
    /// local service-file check the HTTP route doesn't surface).
    public let gatewayRunning: Bool?
    public let gatewayPid: Int?
    public let gatewayState: String?
    public let gatewayHealthURL: String?
    public let gatewayPlatforms: [String: GatewayPlatform]?
    public let gatewayExitReason: String?
    public let gatewayUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case version
        case releaseDate = "release_date"
        case gatewayRunning = "gateway_running"
        case gatewayPid = "gateway_pid"
        case gatewayState = "gateway_state"
        case gatewayHealthURL = "gateway_health_url"
        case gatewayPlatforms = "gateway_platforms"
        case gatewayExitReason = "gateway_exit_reason"
        case gatewayUpdatedAt = "gateway_updated_at"
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

public struct DashboardSessionDetail: Codable, Equatable, Sendable {
    public let id: String
    public let source: String?
}

public struct DashboardSessionMessagesResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    public let messages: [DashboardMessage]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messages
    }
}

public struct DashboardMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: JSONValue?
    public let toolCalls: JSONValue?
    public let toolCallId: String?
    public let toolName: String?
    public let reasoning: String?
    public let reasoningContent: String?

    public var plainText: String? {
        guard let content else { return nil }
        let text = Self.extractText(from: content)
        return text.isEmpty ? nil : text
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoning
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case reasoningContent = "reasoning_content"
    }

    private static func extractText(from value: JSONValue) -> String {
        switch value {
        case let .string(text):
            return text
        case let .array(values):
            return values
                .map(extractText)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let .object(object):
            if case let .string(text)? = object["text"] {
                return text
            }
            if let nested = object["content"] {
                return extractText(from: nested)
            }
            return ""
        default:
            return ""
        }
    }
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

/// One provider row from `GET /api/model/options`. Hermes returns **only
/// authenticated** providers here (no `authenticated` flag), each carrying its
/// curated model-id list. `models` is a flat list of model identifier strings
/// (the dashboard's picker shows them verbatim). Unauthenticated providers are
/// supplied separately by the UI from a static catalog, so this type models the
/// authenticated case only.
public struct DashboardModelProvider: Codable, Equatable, Sendable, Identifiable {
    public let slug: String
    public let name: String?
    public let isCurrent: Bool?
    public let isUserDefined: Bool?
    public let models: [String]
    public let totalModels: Int?
    public let source: String?

    public var id: String { slug }

    /// Friendly label, falling back to the slug when the row omits a name.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return slug
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, models, source
        case isCurrent = "is_current"
        case isUserDefined = "is_user_defined"
        case totalModels = "total_models"
    }

    public init(
        slug: String,
        name: String?,
        isCurrent: Bool? = nil,
        isUserDefined: Bool? = nil,
        models: [String],
        totalModels: Int? = nil,
        source: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.isCurrent = isCurrent
        self.isUserDefined = isUserDefined
        self.models = models
        self.totalModels = totalModels
        self.source = source
    }
}

/// Response of `GET /api/model/options` — the authenticated provider universe
/// plus the currently-selected main `provider`/`model` echoed alongside.
public struct DashboardModelOptions: Codable, Equatable, Sendable {
    public let providers: [DashboardModelProvider]
    public let model: String?
    public let provider: String?
}

/// One auxiliary slot from `GET /api/model/auxiliary`. A slot reads
/// `provider == "auto"` (and an empty `model`) when it's unset and inherits the
/// main model. `task` is the canonical slot key (e.g. `"vision"`).
public struct DashboardAuxiliaryModel: Codable, Equatable, Sendable, Identifiable {
    public let task: String
    public let provider: String?
    public let model: String?
    public let baseURL: String?

    public var id: String { task }

    /// True when the slot falls back to the main model (`provider` empty or the
    /// literal `"auto"`). The dashboard renders these as "auto (use main model)".
    public var isAuto: Bool {
        let normalized = (provider ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return normalized.isEmpty || normalized == "auto"
    }

    enum CodingKeys: String, CodingKey {
        case task, provider, model
        case baseURL = "base_url"
    }
}

/// The main-model assignment echoed by `GET /api/model/auxiliary`.
public struct DashboardMainModel: Codable, Equatable, Sendable {
    public let provider: String?
    public let model: String?
}

/// Response of `GET /api/model/auxiliary` — the main model plus every auxiliary
/// task slot in Hermes' canonical order.
public struct DashboardModelAssignments: Codable, Equatable, Sendable {
    public let tasks: [DashboardAuxiliaryModel]
    public let main: DashboardMainModel
}

/// Target of a `POST /api/model/set`. `main` writes `model.provider`/
/// `model.default`; `auxiliary` writes `auxiliary.<task>.{provider,model}`.
public enum DashboardModelScope: String, Sendable {
    case main
    case auxiliary
}

/// One agent plugin from `GET /api/dashboard/plugins/hub`. Decodes only the
/// fields the native Plugins surface renders; the hub also carries
/// `dashboard_manifest` (web-only tab metadata) and `user_hidden`, which
/// `JSONDecoder` ignores since they aren't modeled here.
public struct DashboardPlugin: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let version: String
    public let description: String
    /// `bundled` | `user` | `git` | `pip` | … — drives the source pill.
    public let source: String
    /// `enabled` | `disabled` | `inactive` — drives the status pill and which
    /// of Enable/Disable the detail pane offers.
    public let runtimeStatus: String
    /// False for plugins that don't ship a dashboard tab ("No dashboard tab").
    public let hasDashboardManifest: Bool
    /// True only for user-installed plugins — gates the Remove button.
    public let canRemove: Bool
    /// True only for git-sourced plugins — gates the Update button.
    public let canUpdateGit: Bool
    public let authRequired: Bool
    public let authCommand: String
    public let path: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, version, description, source, path
        case runtimeStatus = "runtime_status"
        case hasDashboardManifest = "has_dashboard_manifest"
        case canRemove = "can_remove"
        case canUpdateGit = "can_update_git"
        case authRequired = "auth_required"
        case authCommand = "auth_command"
    }
}

public struct DashboardPluginProviderOption: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String

    public var id: String { name }
}

public struct DashboardPluginProviders: Codable, Equatable, Sendable {
    /// Current memory provider; empty string means built-in / none.
    public let memoryProvider: String
    public let memoryOptions: [DashboardPluginProviderOption]
    public let contextEngine: String
    public let contextOptions: [DashboardPluginProviderOption]

    enum CodingKeys: String, CodingKey {
        case memoryProvider = "memory_provider"
        case memoryOptions = "memory_options"
        case contextEngine = "context_engine"
        case contextOptions = "context_options"
    }
}

public struct DashboardPluginsHub: Codable, Equatable, Sendable {
    public let plugins: [DashboardPlugin]
    public let providers: DashboardPluginProviders
}

/// Success payload from `POST /api/dashboard/agent-plugins/install`. The route
/// returns `{ ok, plugin_name, warnings, missing_env, enabled }` on 200 and
/// raises HTTP 400 (`{ detail }`) on failure — which the shared plumbing turns
/// into a thrown `DashboardClientError.http` before this is ever parsed.
/// Decoding defaults every field so a missing key or empty body can't make a
/// genuine success read as a failure.
public struct DashboardPluginInstallResult: Codable, Equatable, Sendable {
    public let ok: Bool
    /// Canonical name the server resolved the install to (e.g. `linear`).
    public let pluginName: String?
    /// Non-fatal advisories (e.g. insecure URL scheme).
    public let warnings: [String]
    /// Names of required env vars the plugin declares but that aren't set yet.
    public let missingEnv: [String]
    /// Whether the plugin was enabled as part of this install.
    public let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case ok, warnings, enabled
        case pluginName = "plugin_name"
        case missingEnv = "missing_env"
    }

    public init(
        ok: Bool = true,
        pluginName: String? = nil,
        warnings: [String] = [],
        missingEnv: [String] = [],
        enabled: Bool = false
    ) {
        self.ok = ok
        self.pluginName = pluginName
        self.warnings = warnings
        self.missingEnv = missingEnv
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? true
        pluginName = try? c.decodeIfPresent(String.self, forKey: .pluginName)
        warnings = (try? c.decode([String].self, forKey: .warnings)) ?? []
        missingEnv = (try? c.decode([String].self, forKey: .missingEnv)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
    }

    /// Parses a raw install body, defaulting to an empty success on an empty or
    /// unparseable body (the route always sends the dict on 200, so this guard
    /// only covers defensive edge cases).
    init(data: Data) {
        if !data.isEmpty,
           let decoded = try? JSONDecoder().decode(DashboardPluginInstallResult.self, from: data) {
            self = decoded
        } else {
            self = DashboardPluginInstallResult()
        }
    }
}

/// One known Hermes environment variable from `GET /api/env`. The dashboard
/// enumerates only Hermes' `OPTIONAL_ENV_VARS` (~139 entries), keyed by the var
/// name, so `name` is injected from the dict key during decode rather than
/// carried in the value object. Values are redacted server-side
/// (`redactedValue`); the real value is fetched on demand via
/// ``DashboardClient/revealEnvVar(key:)``.
public struct DashboardEnvVar: Codable, Equatable, Sendable, Identifiable {
    /// The env var name, e.g. `ANTHROPIC_API_KEY`. Injected from the response
    /// dict key — not a field on the value object itself.
    public let name: String
    public let isSet: Bool
    /// Masked value (e.g. `sk-…abcd`) shown until the user reveals it. Nil when
    /// the var isn't set.
    public let redactedValue: String?
    public let description: String
    public let url: String?
    /// `provider` | `messaging` | `tool` | `setting` | `skill`. Drives the
    /// list's section grouping.
    public let category: String
    /// True for secrets (API keys/tokens) — the UI masks these and offers a
    /// per-row Reveal action.
    public let isPassword: Bool
    /// Tool/skill names that consume this var, surfaced in the detail pane.
    public let tools: [String]
    /// Advanced/rarely-needed var, hidden behind the "Show advanced" toggle.
    public let advanced: Bool

    public var id: String { name }

    public init(
        name: String,
        isSet: Bool,
        redactedValue: String?,
        description: String,
        url: String?,
        category: String,
        isPassword: Bool,
        tools: [String],
        advanced: Bool
    ) {
        self.name = name
        self.isSet = isSet
        self.redactedValue = redactedValue
        self.description = description
        self.url = url
        self.category = category
        self.isPassword = isPassword
        self.tools = tools
        self.advanced = advanced
    }
}

/// Resolved metadata for the currently configured model (`GET /api/model/info`).
/// `auto*` is the auto-detected context length, `config*` the user override (0
/// when unset), `effective*` the one actually used. `capabilities` is `{}` when
/// the server can't resolve model metadata, so every field is optional. Reuses
/// the shared `DashboardModelCapabilities` (defined in `AnalyticsModels.swift`).
public struct DashboardModelInfo: Codable, Equatable, Sendable {
    public let model: String
    public let provider: String
    public let autoContextLength: Int?
    public let configContextLength: Int?
    public let effectiveContextLength: Int?
    public let capabilities: DashboardModelCapabilities?

    enum CodingKeys: String, CodingKey {
        case model, provider, capabilities
        case autoContextLength = "auto_context_length"
        case configContextLength = "config_context_length"
        case effectiveContextLength = "effective_context_length"
    }
}

/// One configurable toolset row from `GET /api/tools/toolsets`. `enabled` is
/// whether it's on for the dashboard (`cli`) platform; `configured` is whether
/// its required credentials/keys are present; `available` tracks `enabled` on
/// the current server. `tools` is the sorted list of tool ids it contributes.
public struct DashboardToolset: Codable, Equatable, Sendable {
    public let name: String
    public let label: String
    public let description: String?
    public let enabled: Bool
    public let available: Bool?
    public let configured: Bool?
    public let tools: [String]
}

/// Result of toggling a toolset (`PUT /api/tools/toolsets/{name}`).
public struct DashboardToolsetToggleResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let name: String
    public let enabled: Bool
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

    public func sessionDetail(id: String) async throws -> DashboardSessionDetail {
        try await get(path: "/api/sessions/\(id)")
    }

    public func sessionMessages(id: String) async throws -> DashboardSessionMessagesResponse {
        try await get(path: "/api/sessions/\(id)/messages")
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

    /// Creates a profile by cloning the default. The dashboard API only clones
    /// from default (`clone_from_default`); cloning an arbitrary source profile
    /// has to go through the CLI. `no_skills` skips copying the `skills/` tree.
    public func createProfile(name: String, cloneFromDefault: Bool = true, noSkills: Bool = false) async throws {
        let body = ProfileCreateBody(name: name, cloneFromDefault: cloneFromDefault, noSkills: noSkills)
        try await sendNoContent(method: "POST", path: "/api/profiles", body: body)
    }

    /// Renames a profile in place. `default` is rejected by the server.
    public func renameProfile(name: String, newName: String) async throws {
        let body = ProfileRenameBody(newName: newName)
        try await sendNoContent(method: "PATCH", path: "/api/profiles/\(name)", body: body)
    }

    /// Deletes a profile. The server forces `yes=True`, so no extra confirmation
    /// flag is sent; `default` is rejected.
    public func deleteProfile(name: String) async throws {
        try await sendNoContent(method: "DELETE", path: "/api/profiles/\(name)")
    }

    private struct ProfileCreateBody: Encodable {
        let name: String
        let cloneFromDefault: Bool
        let noSkills: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case cloneFromDefault = "clone_from_default"
            case noSkills = "no_skills"
        }
    }

    private struct ProfileRenameBody: Encodable {
        let newName: String

        enum CodingKeys: String, CodingKey {
            case newName = "new_name"
        }
    }

    private struct ProfilesResponse: Decodable {
        let profiles: [DashboardProfile]
    }

    // MARK: - Models

    /// Authenticated providers + each provider's curated model list. Hermes
    /// omits unauthenticated providers entirely, so the Models screen overlays
    /// a static known-provider catalog to surface those disabled.
    public func getModelOptions() async throws -> DashboardModelOptions {
        try await get(path: "/api/model/options")
    }

    /// Current assignments: the main model plus the auxiliary task slots
    /// (unset slots read as `provider:"auto"`).
    public func getModelAssignments() async throws -> DashboardModelAssignments {
        try await get(path: "/api/model/auxiliary")
    }

    /// Assigns a provider/model to a slot. For `scope == .auxiliary`: a slot
    /// name overrides one task, `""` assigns every slot, and `"__reset__"`
    /// resets all to auto (pass empty `provider`/`model`).
    ///
    /// For `scope == .main` the server ignores `task`, so we drop it from the
    /// body entirely rather than send `task:""` — the auxiliary branch reads an
    /// empty task as "every slot", and omitting the field removes any chance a
    /// main write is misrouted there on a server whose dispatch differs.
    public func setModel(
        scope: DashboardModelScope,
        task: String = "",
        provider: String,
        model: String
    ) async throws {
        let body = ModelSetBody(
            scope: scope.rawValue,
            task: scope == .main ? nil : task,
            provider: provider,
            model: model
        )
        try await sendNoContent(method: "POST", path: "/api/model/set", body: body)
    }

    private struct ModelSetBody: Encodable {
        let scope: String
        /// Optional so a `nil` is omitted from the JSON (synthesized
        /// `encodeIfPresent`) — used to drop `task` for main writes.
        let task: String?
        let provider: String
        let model: String
    }

    /// Resolved metadata (context length, capabilities) for the currently
    /// configured main model. The desktop reads this for its model badge.
    public func getModelInfo() async throws -> DashboardModelInfo {
        try await get(path: "/api/model/info")
    }

    // MARK: - Tools / toolsets

    /// The configurable toolsets and their enabled/configured state. Backs the
    /// tools picker, and supersedes the `hermes tools list` CLI fallback.
    public func getToolsets() async throws -> [DashboardToolset] {
        try await get(path: "/api/tools/toolsets")
    }

    /// Enable or disable a toolset for the dashboard (`cli`) platform. Persists
    /// to `platform_toolsets.cli` the same way the CLI `hermes tools` picker
    /// does, so GUI and CLI stay in lockstep — superseding the
    /// `hermes tools enable/disable` CLI fallback. Returns 400 for unknown keys.
    @discardableResult
    public func setToolset(name: String, enabled: Bool) async throws -> DashboardToolsetToggleResult {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: Self.queryComponentAllowed) ?? name
        return try await sendDecoding(
            method: "PUT",
            path: "/api/tools/toolsets/\(encodedName)",
            body: ToolsetToggleBody(enabled: enabled)
        )
    }

    private struct ToolsetToggleBody: Encodable {
        let enabled: Bool
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

    /// The built-in default config (`GET /api/config/defaults`), returned
    /// verbatim as a `JSONValue` so arbitrary keys round-trip — the desktop
    /// uses it to show "(default)" hints and reset fields.
    public func getConfigDefaults() async throws -> JSONValue {
        try await get(path: "/api/config/defaults")
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

    public func getSoul(profile: String) async throws -> String {
        let response: SoulResponse = try await get(path: "/api/profiles/\(profile)/soul")
        return response.content
    }

    public func updateSoul(profile: String, content: String) async throws {
        try await sendNoContent(method: "PUT", path: "/api/profiles/\(profile)/soul", body: SoulUpdateBody(content: content))
    }

    private struct SoulResponse: Decodable {
        let content: String
        let exists: Bool?   // present on GET; optional keeps decode lenient
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

    // MARK: - Plugins

    /// Unified plugins payload — installed plugins plus the runtime provider
    /// selections (memory provider / context engine) and their options.
    public func getPluginsHub() async throws -> DashboardPluginsHub {
        try await get(path: "/api/dashboard/plugins/hub")
    }

    /// Installs a plugin from `owner/repo` or a full Git URL. `enable` activates
    /// it after install; `force` reinstalls over an existing copy. Returns the
    /// server's (leniently parsed) install summary so callers can confirm what
    /// landed; a non-2xx still throws via the shared plumbing.
    @discardableResult
    public func installPlugin(identifier: String, force: Bool, enable: Bool) async throws -> DashboardPluginInstallResult {
        let body = PluginInstallBody(identifier: identifier, force: force, enable: enable)
        let data = try await sendRawData(method: "POST", path: "/api/dashboard/agent-plugins/install", body: body)
        return DashboardPluginInstallResult(data: data)
    }

    /// Enables or disables a plugin. The `{name:path}` route accepts slashes, so
    /// names like `browser/browser_use` interpolate directly as path segments
    /// (`URLComponents.path` preserves `/` and percent-encodes the rest).
    public func setPluginEnabled(name: String, enabled: Bool) async throws {
        try await sendNoContent(
            method: "POST",
            path: "/api/dashboard/agent-plugins/\(name)/\(enabled ? "enable" : "disable")"
        )
    }

    /// `git pull` for a git-sourced plugin. Only valid when `canUpdateGit`.
    public func updatePlugin(name: String) async throws {
        try await sendNoContent(method: "POST", path: "/api/dashboard/agent-plugins/\(name)/update")
    }

    /// Removes a user-installed plugin. Only valid when `canRemove`.
    public func removePlugin(name: String) async throws {
        try await sendNoContent(method: "DELETE", path: "/api/dashboard/agent-plugins/\(name)")
    }

    /// Writes `memory.provider` / `context.engine` to `config.yaml` (takes
    /// effect next session). Nil leaves a field untouched; an empty memory
    /// provider string selects the built-in / none provider.
    public func setPluginProviders(memoryProvider: String?, contextEngine: String?) async throws {
        let body = PluginProvidersBody(memoryProvider: memoryProvider, contextEngine: contextEngine)
        try await sendNoContent(method: "PUT", path: "/api/dashboard/plugin-providers", body: body)
    }

    private struct PluginInstallBody: Encodable {
        let identifier: String
        let force: Bool
        let enable: Bool
    }

    private struct PluginProvidersBody: Encodable {
        let memoryProvider: String?
        let contextEngine: String?

        enum CodingKeys: String, CodingKey {
            case memoryProvider = "memory_provider"
            case contextEngine = "context_engine"
        }
    }

    // MARK: - Environment

    /// Hermes' known `.env` variables (`OPTIONAL_ENV_VARS`), each carrying its
    /// set state, redacted value, and metadata. `GET /api/env` returns a dict
    /// keyed by var name; `JSONDecoder` into a Swift `Dictionary` doesn't
    /// preserve insertion order, so the result is sorted by `(category-rank,
    /// name)` for a deterministic UI (alphabetical within each category —
    /// full definition-order would need order-preserving parsing, which is
    /// overkill here).
    public func listEnvVars() async throws -> [DashboardEnvVar] {
        let dict: [String: EnvVarInfoDTO] = try await get(path: "/api/env")
        return dict
            .map { name, info in
                DashboardEnvVar(
                    name: name,
                    isSet: info.isSet,
                    redactedValue: info.redactedValue,
                    description: info.description ?? "",
                    url: info.url,
                    category: info.category ?? "",
                    isPassword: info.isPassword ?? false,
                    tools: info.tools ?? [],
                    advanced: info.advanced ?? false
                )
            }
            .sorted { lhs, rhs in
                let l = Self.categoryRank(lhs.category)
                let r = Self.categoryRank(rhs.category)
                return l == r ? lhs.name < rhs.name : l < r
            }
    }

    /// Sets or updates a known env var via `PUT /api/env`. Returns server-side
    /// `is_managed()` rejections (and any other failure) as a thrown
    /// `DashboardClientError.http`.
    public func setEnvVar(key: String, value: String) async throws {
        try await sendNoContent(method: "PUT", path: "/api/env", body: EnvVarUpdateBody(key: key, value: value))
    }

    /// Removes a var from `.env` via `DELETE /api/env` (JSON body). A key not
    /// present surfaces as `DashboardClientError.http(statusCode: 404, …)`.
    public func deleteEnvVar(key: String) async throws {
        try await sendNoContent(method: "DELETE", path: "/api/env", body: EnvVarDeleteBody(key: key))
    }

    /// Fetches the unredacted value of one var via `POST /api/env/reveal`. The
    /// route is rate-limited (5 per 30s) — excess reveals surface as
    /// `DashboardClientError.http(statusCode: 429, …)`; an unset key as 404.
    public func revealEnvVar(key: String) async throws -> String {
        let response: EnvVarRevealResponse = try await sendDecoding(
            method: "POST", path: "/api/env/reveal", body: EnvVarRevealBody(key: key)
        )
        return response.value
    }

    /// UI grouping order for the env categories Hermes returns. Kept in step
    /// with `EnvCategory.allCases` in `EnvironmentView` (provider, messaging,
    /// tool, skill, setting) so the client's cross-category sort and the view's
    /// section order can't silently diverge. Unknown categories sort last
    /// (into the UI's "Other" section).
    private static func categoryRank(_ category: String) -> Int {
        switch category {
        case "provider": return 0
        case "messaging": return 1
        case "tool": return 2
        case "skill": return 3
        case "setting": return 4
        default: return 5
        }
    }

    /// Value object of one `GET /api/env` entry (the var name is the dict key,
    /// injected separately). Every metadata field is optional so a leaner
    /// upstream payload still decodes.
    private struct EnvVarInfoDTO: Decodable {
        let isSet: Bool
        let redactedValue: String?
        let description: String?
        let url: String?
        let category: String?
        let isPassword: Bool?
        let tools: [String]?
        let advanced: Bool?

        enum CodingKeys: String, CodingKey {
            case isSet = "is_set"
            case redactedValue = "redacted_value"
            case description, url, category, tools, advanced
            case isPassword = "is_password"
        }
    }

    private struct EnvVarUpdateBody: Encodable {
        let key: String
        let value: String
    }

    private struct EnvVarDeleteBody: Encodable {
        let key: String
    }

    private struct EnvVarRevealBody: Encodable {
        let key: String
    }

    private struct EnvVarRevealResponse: Decodable {
        let key: String
        let value: String
    }

    // MARK: - Plumbing

    // `get` / `sendDecoding` / `sendNoContent` are `internal` (not `private`)
    // so the kanban surface — split into `DashboardClient+Kanban.swift` because
    // it adds ~18 methods — can reuse the exact same request plumbing. The
    // stored properties and the lower `dispatch`/`sendOnce*` layer stay private,
    // so nothing leaks outside `HermesKit`.
    func get<T: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        try await sendDecoding(method: "GET", path: path, queryItems: queryItems)
    }

    func sendDecoding<T: Decodable>(
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

    func sendNoContent(
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
