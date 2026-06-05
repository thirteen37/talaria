import Foundation

// Codable models for the Hermes dashboard **usage analytics** routes
// (`GET /api/analytics/usage`, `GET /api/analytics/models`), backing the native
// "Usage" management surface. The shapes mirror `hermes_cli/web_server.py`'s
// `get_usage_analytics` / `get_models_analytics` handlers (verified against the
// Hermes 0.14.0 source).
//
// Every token / cost / count field is decoded as **optional**: the routes build
// each row straight from SQL `SUM(...)` / `COUNT(*)` aggregates, and a `SUM`
// over zero matching rows is `NULL` — so an empty-history server (a fresh
// install, or a `days` window with no sessions) returns `null` for the token and
// api-call fields while the COUNT and `COALESCE(...,0)` cost fields are 0. Call
// sites coalesce with `?? 0`.

// MARK: - Usage analytics (`GET /api/analytics/usage`)

/// `GET /api/analytics/usage?days=N` response. The `skills` insights block the
/// route also returns is intentionally not decoded — the Usage screen surfaces
/// tokens/cost/sessions, and unknown keys are ignored by `Codable`.
public struct DashboardUsageAnalytics: Codable, Equatable, Sendable {
    /// Per-day rows, oldest first (`GROUP BY day ORDER BY day`).
    public let daily: [DashboardUsageDaily]
    /// Per-model rows, busiest first (`ORDER BY total tokens DESC`).
    public let byModel: [DashboardUsageByModel]
    public let totals: DashboardUsageTotals
    /// Echo of the requested window (`days`).
    public let periodDays: Int?

    public init(
        daily: [DashboardUsageDaily] = [],
        byModel: [DashboardUsageByModel] = [],
        totals: DashboardUsageTotals = DashboardUsageTotals(),
        periodDays: Int? = nil
    ) {
        self.daily = daily
        self.byModel = byModel
        self.totals = totals
        self.periodDays = periodDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daily = try c.decodeIfPresent([DashboardUsageDaily].self, forKey: .daily) ?? []
        byModel = try c.decodeIfPresent([DashboardUsageByModel].self, forKey: .byModel) ?? []
        totals = try c.decodeIfPresent(DashboardUsageTotals.self, forKey: .totals) ?? DashboardUsageTotals()
        periodDays = try c.decodeIfPresent(Int.self, forKey: .periodDays)
    }

    enum CodingKeys: String, CodingKey {
        case daily
        case byModel = "by_model"
        case totals
        case periodDays = "period_days"
    }
}

/// One day's usage row from `daily[]`. `day` is an ISO `yyyy-MM-dd` string
/// (SQLite `date(started_at,'unixepoch')`); every numeric field is optional.
public struct DashboardUsageDaily: Codable, Equatable, Sendable, Identifiable {
    public let day: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let reasoningTokens: Int?
    public let estimatedCost: Double?
    public let actualCost: Double?
    public let sessions: Int?
    public let apiCalls: Int?

    public var id: String { day }

    /// Total tokens for the day (input + output), coalescing nulls to 0.
    public var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }

    public init(
        day: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimatedCost: Double? = nil,
        actualCost: Double? = nil,
        sessions: Int? = nil,
        apiCalls: Int? = nil
    ) {
        self.day = day
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCost = estimatedCost
        self.actualCost = actualCost
        self.sessions = sessions
        self.apiCalls = apiCalls
    }

    enum CodingKeys: String, CodingKey {
        case day
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case reasoningTokens = "reasoning_tokens"
        case estimatedCost = "estimated_cost"
        case actualCost = "actual_cost"
        case sessions
        case apiCalls = "api_calls"
    }
}

/// One model's usage row from `by_model[]`.
public struct DashboardUsageByModel: Codable, Equatable, Sendable, Identifiable {
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let estimatedCost: Double?
    public let sessions: Int?
    public let apiCalls: Int?

    public var id: String { model }

    public var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }

    public init(
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        estimatedCost: Double? = nil,
        sessions: Int? = nil,
        apiCalls: Int? = nil
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCost = estimatedCost
        self.sessions = sessions
        self.apiCalls = apiCalls
    }

    enum CodingKeys: String, CodingKey {
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case estimatedCost = "estimated_cost"
        case sessions
        case apiCalls = "api_calls"
    }
}

/// Window-wide totals from `totals`. On an empty-history server the SUM fields
/// decode `null` (no rows) while `totalSessions` is 0 and the cost fields are
/// `COALESCE(...,0)` 0 — so every field is optional and coalesced.
public struct DashboardUsageTotals: Codable, Equatable, Sendable {
    public let totalInput: Int?
    public let totalOutput: Int?
    public let totalCacheRead: Int?
    public let totalReasoning: Int?
    public let totalEstimatedCost: Double?
    public let totalActualCost: Double?
    public let totalSessions: Int?
    public let totalApiCalls: Int?

    public var totalTokens: Int { (totalInput ?? 0) + (totalOutput ?? 0) }

    public init(
        totalInput: Int? = nil,
        totalOutput: Int? = nil,
        totalCacheRead: Int? = nil,
        totalReasoning: Int? = nil,
        totalEstimatedCost: Double? = nil,
        totalActualCost: Double? = nil,
        totalSessions: Int? = nil,
        totalApiCalls: Int? = nil
    ) {
        self.totalInput = totalInput
        self.totalOutput = totalOutput
        self.totalCacheRead = totalCacheRead
        self.totalReasoning = totalReasoning
        self.totalEstimatedCost = totalEstimatedCost
        self.totalActualCost = totalActualCost
        self.totalSessions = totalSessions
        self.totalApiCalls = totalApiCalls
    }

    enum CodingKeys: String, CodingKey {
        case totalInput = "total_input"
        case totalOutput = "total_output"
        case totalCacheRead = "total_cache_read"
        case totalReasoning = "total_reasoning"
        case totalEstimatedCost = "total_estimated_cost"
        case totalActualCost = "total_actual_cost"
        case totalSessions = "total_sessions"
        case totalApiCalls = "total_api_calls"
    }
}

// MARK: - Model analytics (`GET /api/analytics/models`)

/// `GET /api/analytics/models?days=N` response — richer per-model rows than the
/// usage route's `by_model`, with cache/reasoning tokens, actual cost, tool
/// calls, last-used timestamp, average tokens/session, and a `capabilities`
/// block from models.dev. Optional enrichment for a future "Models" tab.
public struct DashboardModelAnalytics: Codable, Equatable, Sendable {
    public let models: [DashboardModelAnalyticsRow]
    public let totals: DashboardModelAnalyticsTotals
    public let periodDays: Int?

    public init(
        models: [DashboardModelAnalyticsRow] = [],
        totals: DashboardModelAnalyticsTotals = DashboardModelAnalyticsTotals(),
        periodDays: Int? = nil
    ) {
        self.models = models
        self.totals = totals
        self.periodDays = periodDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([DashboardModelAnalyticsRow].self, forKey: .models) ?? []
        totals = try c.decodeIfPresent(DashboardModelAnalyticsTotals.self, forKey: .totals) ?? DashboardModelAnalyticsTotals()
        periodDays = try c.decodeIfPresent(Int.self, forKey: .periodDays)
    }

    enum CodingKeys: String, CodingKey {
        case models
        case totals
        case periodDays = "period_days"
    }
}

/// One model's row from `models[]` in the model-analytics route. Keyed by
/// `model` + `provider` since the route groups on `(model, billing_provider)`.
public struct DashboardModelAnalyticsRow: Codable, Equatable, Sendable, Identifiable {
    public let model: String
    public let provider: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let reasoningTokens: Int?
    public let estimatedCost: Double?
    public let actualCost: Double?
    public let sessions: Int?
    public let apiCalls: Int?
    public let toolCalls: Int?
    /// Unix epoch seconds of the most recent session on this model (`MAX`).
    public let lastUsedAt: Double?
    public let avgTokensPerSession: Double?
    public let capabilities: DashboardModelCapabilities?

    public var id: String { "\(model)\u{1F}\(provider ?? "")" }

    public var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }

    public init(
        model: String,
        provider: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimatedCost: Double? = nil,
        actualCost: Double? = nil,
        sessions: Int? = nil,
        apiCalls: Int? = nil,
        toolCalls: Int? = nil,
        lastUsedAt: Double? = nil,
        avgTokensPerSession: Double? = nil,
        capabilities: DashboardModelCapabilities? = nil
    ) {
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
        self.estimatedCost = estimatedCost
        self.actualCost = actualCost
        self.sessions = sessions
        self.apiCalls = apiCalls
        self.toolCalls = toolCalls
        self.lastUsedAt = lastUsedAt
        self.avgTokensPerSession = avgTokensPerSession
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case model, provider, sessions, capabilities
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case reasoningTokens = "reasoning_tokens"
        case estimatedCost = "estimated_cost"
        case actualCost = "actual_cost"
        case apiCalls = "api_calls"
        case toolCalls = "tool_calls"
        case lastUsedAt = "last_used_at"
        case avgTokensPerSession = "avg_tokens_per_session"
    }
}

/// models.dev capability metadata attached to a model-analytics row. All fields
/// optional — the route swallows any lookup failure and emits an empty object.
public struct DashboardModelCapabilities: Codable, Equatable, Sendable {
    public let supportsTools: Bool?
    public let supportsVision: Bool?
    public let supportsReasoning: Bool?
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let modelFamily: String?

    public init(
        supportsTools: Bool? = nil,
        supportsVision: Bool? = nil,
        supportsReasoning: Bool? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        modelFamily: String? = nil
    ) {
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsReasoning = supportsReasoning
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.modelFamily = modelFamily
    }

    enum CodingKeys: String, CodingKey {
        case supportsTools = "supports_tools"
        case supportsVision = "supports_vision"
        case supportsReasoning = "supports_reasoning"
        case contextWindow = "context_window"
        case maxOutputTokens = "max_output_tokens"
        case modelFamily = "model_family"
    }
}

/// Window-wide totals from the model-analytics route. Adds `distinctModels` to
/// the usage-route totals; every numeric field is optional and coalesced.
public struct DashboardModelAnalyticsTotals: Codable, Equatable, Sendable {
    public let distinctModels: Int?
    public let totalInput: Int?
    public let totalOutput: Int?
    public let totalCacheRead: Int?
    public let totalReasoning: Int?
    public let totalEstimatedCost: Double?
    public let totalActualCost: Double?
    public let totalSessions: Int?
    public let totalApiCalls: Int?

    public init(
        distinctModels: Int? = nil,
        totalInput: Int? = nil,
        totalOutput: Int? = nil,
        totalCacheRead: Int? = nil,
        totalReasoning: Int? = nil,
        totalEstimatedCost: Double? = nil,
        totalActualCost: Double? = nil,
        totalSessions: Int? = nil,
        totalApiCalls: Int? = nil
    ) {
        self.distinctModels = distinctModels
        self.totalInput = totalInput
        self.totalOutput = totalOutput
        self.totalCacheRead = totalCacheRead
        self.totalReasoning = totalReasoning
        self.totalEstimatedCost = totalEstimatedCost
        self.totalActualCost = totalActualCost
        self.totalSessions = totalSessions
        self.totalApiCalls = totalApiCalls
    }

    enum CodingKeys: String, CodingKey {
        case distinctModels = "distinct_models"
        case totalInput = "total_input"
        case totalOutput = "total_output"
        case totalCacheRead = "total_cache_read"
        case totalReasoning = "total_reasoning"
        case totalEstimatedCost = "total_estimated_cost"
        case totalActualCost = "total_actual_cost"
        case totalSessions = "total_sessions"
        case totalApiCalls = "total_api_calls"
    }
}
