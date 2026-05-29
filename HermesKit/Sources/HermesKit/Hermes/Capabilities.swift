import Foundation

public enum HermesCapability: String, CaseIterable, Codable, Sendable {
    case acp
    case permissions
    case diffs
    case toolsEnablePerPlatform
    /// `hermes dashboard` HTTP API on `127.0.0.1`. Prerequisite for every
    /// non-chat surface (Sessions, Updates, Skills, Cron, Logs) since dashboard
    /// mode is mandatory in this release — there's no CLI/SQLite scraper
    /// fallback. Not enforced at profile-load: a profile on older Hermes still
    /// loads and chat still works over ACP, but the dashboard surfaces show a
    /// `capabilityBanner` warning and remain on their "connecting…" placeholder
    /// because the spawn fails. (No hard upgrade gate today.)
    case requiresDashboard
}

public struct CapabilityTable: Sendable {
    public let minimumVersions: [HermesCapability: HermesVersion]

    public init(minimumVersions: [HermesCapability: HermesVersion] = CapabilityTable.defaults) {
        self.minimumVersions = minimumVersions
    }

    public func supports(_ capability: HermesCapability, version: HermesVersion?) -> Bool {
        guard let required = minimumVersions[capability], let version else {
            return false
        }
        return version >= required
    }

    /// Uniform `has(_:in:)` query for view-level gating. Defers to
    /// `supports(_:version:)`; named to read fluently at call sites
    /// (`if capabilities.has(.requiresDashboard, in: version) { ... }`).
    public func has(_ capability: HermesCapability, in version: HermesVersion?) -> Bool {
        supports(capability, version: version)
    }

    /// Default minimum Hermes versions per capability.
    ///
    /// Pins are sourced from the Hermes repo's git history mapped against
    /// the semver in `pyproject.toml` at each calver release tag.
    /// See `RELEASE_SETUP.md` §6 for the resolution method.
    public static let defaults: [HermesCapability: HermesVersion] = [
        // ACP adapter introduced in PR #1254, first shipped in v2026.3.17.
        .acp: HermesVersion(major: 0, minor: 3, patch: 0),
        .permissions: HermesVersion(major: 0, minor: 3, patch: 0),
        .diffs: HermesVersion(major: 0, minor: 3, patch: 0),
        // `hermes tools enable/disable/list` shipped via #1652, first in v2026.3.23.
        // Still on the CLI path because the dashboard exposes
        // `GET /api/tools/toolsets` (list) but no toggle route.
        .toolsEnablePerPlatform: HermesVersion(major: 0, minor: 4, patch: 0),
        // FastAPI dashboard (`hermes dashboard` / `web_server.py`) verified
        // live against a running instance reporting version 0.14.0 / release
        // 2026.5.16. Consulted only by `capabilityBanner` for the per-surface
        // warning — not a profile-load gate; an older-Hermes profile still
        // loads, its dashboard surfaces just won't come online.
        .requiresDashboard: HermesVersion(major: 0, minor: 14, patch: 0),
    ]
}
