import Foundation

public enum HermesCapability: String, CaseIterable, Codable, Sendable {
    case acp
    case permissions
    case diffs
    case updateCheck
    case toolsEnablePerPlatform
    /// `hermes dashboard` HTTP API on `127.0.0.1`. Prerequisite for every
    /// non-chat surface (Sessions, Skills, Cron, Logs) since dashboard
    /// mode is mandatory in this release — there's no CLI/SQLite scraper
    /// fallback. Not enforced at profile-load: a profile on older Hermes still
    /// loads and chat still works over ACP, but the dashboard surfaces show a
    /// `capabilityBanner` warning and remain on their "connecting…" placeholder
    /// because the spawn fails. (No hard upgrade gate today.)
    case requiresDashboard
    /// `hermes dashboard`'s `/api/model/*` routes (`options`, `auxiliary`,
    /// `set`) backing the Models management screen. Ships in the same
    /// `web_server.py` as the dashboard itself, so it shares the dashboard pin.
    /// Below it the Models screen shows a `capabilityBanner` warning rather
    /// than breaking.
    case requiresModelAPI
    /// `hermes dashboard`'s `/api/env*` routes (`GET`/`PUT`/`DELETE /api/env`,
    /// `POST /api/env/reveal`) backing the Environment management screen. Ships
    /// in the same `web_server.py` as the dashboard itself, so it shares the
    /// dashboard pin. Below it the Environment screen shows a `capabilityBanner`
    /// warning rather than breaking.
    case requiresEnvAPI
    /// `hermes dashboard`'s `/api/mcp/*` routes (servers list/add/delete/test,
    /// `/enabled` toggle, catalog browse + install) backing the MCP Servers
    /// management screen. Added *after* the 0.14.0 dashboard — they shipped in
    /// the "full administration panel" change (`web_server.py`, Hermes #36704),
    /// so they carry a later pin than the base dashboard. Below it the MCP
    /// screen shows a `capabilityBanner` warning rather than breaking.
    case requiresMCPAPI
    /// `hermes dashboard`'s `/api/ws` JSON-RPC chat gateway — the WebSocket
    /// endpoint that drives live chat the same way Hermes Desktop does, letting
    /// Talaria run chat through the dashboard instead of a separate `hermes acp`
    /// subprocess. Ships in the same `web_server.py` as the dashboard (it drives
    /// the `tui_gateway.dispatch` surface), so it shares the dashboard pin. Below
    /// it, a window falls back to the ACP chat backend. See `docs/gateway-chat.md`.
    case gatewayChat
    /// `hermes skills install/update/uninstall` — the Skills Hub *mutation*
    /// affordances (search is plain public HTTP and is **not** gated by this).
    /// These go through the CLI-fallback admin runner (no dashboard route
    /// exists), so the gate is on the CLI surface, not the dashboard. Below it
    /// the Skills screen still lists/toggles and still searches, but the
    /// Install/Update/Remove controls show a `capabilityBanner` warning.
    case skillsHub
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
        // `hermes update --check` flag added by #10318, first in v2026.4.30.
        .updateCheck: HermesVersion(major: 0, minor: 12, patch: 0),
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
        // `/api/model/{options,auxiliary,set}` are defined in the same
        // `web_server.py` that ships the 0.14.0 dashboard (verified against the
        // live 0.14.0 / release 2026.5.16 instance), so the model API shares
        // the dashboard's introducing version. No separate, later gate.
        .requiresModelAPI: HermesVersion(major: 0, minor: 14, patch: 0),
        // `/api/env*` (env-var read/set/delete/reveal) are defined in the same
        // `web_server.py` that ships the 0.14.0 dashboard (verified against the
        // live 0.14.0 / release 2026.5.16 instance), so the env API shares the
        // dashboard's introducing version. No separate, later gate.
        .requiresEnvAPI: HermesVersion(major: 0, minor: 14, patch: 0),
        // `/api/mcp/*` (MCP server registry + catalog) was added later than the
        // base dashboard, in the "full administration panel" change
        // (`hermes_cli/web_server.py`, Hermes #36704, commit b571ec2 — 2026-06-01,
        // `pyproject.toml` version 0.15.1). Not yet in a tagged calver release at
        // time of writing, so the pin is the semver from that commit's pyproject.
        .requiresMCPAPI: HermesVersion(major: 0, minor: 15, patch: 1),
        // `/api/ws` chat gateway is part of the dashboard server (`web_server.py`,
        // driving `tui_gateway.dispatch`), present in the same builds as the
        // dashboard. Shares the dashboard's introducing pin; below it a window
        // stays on the ACP chat backend.
        .gatewayChat: HermesVersion(major: 0, minor: 14, patch: 0),
        // `hermes skills install/update/uninstall` — verified non-interactive
        // against an installed Hermes v0.14.0 (`--yes` on install/update;
        // uninstall lacks `--yes` and is driven via stdin). The install/search
        // hub machinery itself shipped earlier (per `RELEASE_v0.12.0.md`), so
        // this pin can be lowered if the exact CLI shape is re-verified on an
        // older build; pinned to the verified floor for now.
        .skillsHub: HermesVersion(major: 0, minor: 14, patch: 0),
    ]
}
