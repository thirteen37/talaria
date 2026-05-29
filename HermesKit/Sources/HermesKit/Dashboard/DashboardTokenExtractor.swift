import Foundation

/// Pulls the per-process session token out of the dashboard SPA's index HTML.
///
/// Hermes' `hermes dashboard` (FastAPI/Uvicorn on loopback) generates the
/// token with `secrets.token_urlsafe(32)` per process and injects it into the
/// SPA's `<script>` boot block. There is no env-var, file, or endpoint that
/// exposes the token to a non-browser client today; until upstream adds one,
/// the SPA scrape is the only path. Kept as a free function rather than a
/// protocol because we only have one extraction strategy right now — promote
/// to a protocol the day Hermes ships `HERMES_DASHBOARD_TOKEN` or similar.
public enum DashboardTokenExtractor {
    /// Returns the token value if the SPA boot block is present and the
    /// value is non-empty. Nil for any other shape — callers retry on `GET /`
    /// after re-spawning the supervisor.
    public static func extract(fromHTML html: String) -> String? {
        // Inlined rather than stored on the type because `Regex` isn't
        // `Sendable` and Swift 6 forbids a non-Sendable mutable global.
        let pattern = /window\.__HERMES_SESSION_TOKEN__\s*=\s*"([^"]*)"/
        guard let match = html.firstMatch(of: pattern) else { return nil }
        let value = String(match.output.1)
        return value.isEmpty ? nil : value
    }
}
