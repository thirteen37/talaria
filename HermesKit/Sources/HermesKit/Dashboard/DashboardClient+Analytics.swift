import Foundation

// Client methods for the Hermes dashboard **usage analytics** routes
// (`/api/analytics/*`). Split out of `DashboardClient.swift` like the Kanban and
// MCP surfaces, reusing the internal `get` plumbing. Both routes are read-only
// and take a `days` window (default 30); the route shapes mirror
// `hermes_cli/web_server.py` (verified against the Hermes 0.14.0 source).
public extension DashboardClient {
    /// `GET /api/analytics/usage?days=N` — daily + per-model usage rows and
    /// window totals (tokens, cost, sessions, api calls). Returns the decoded
    /// payload directly (not wrapped).
    func getUsageAnalytics(days: Int = 30) async throws -> DashboardUsageAnalytics {
        try await get(
            path: "/api/analytics/usage",
            queryItems: [URLQueryItem(name: "days", value: String(days))]
        )
    }

    /// `GET /api/analytics/models?days=N` — richer per-model analytics with
    /// cache/reasoning tokens, actual cost, tool calls, and capability metadata.
    /// Optional enrichment beyond the usage route's `by_model`.
    func getModelAnalytics(days: Int = 30) async throws -> DashboardModelAnalytics {
        try await get(
            path: "/api/analytics/models",
            queryItems: [URLQueryItem(name: "days", value: String(days))]
        )
    }
}
