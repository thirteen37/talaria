import Foundation

public enum HermesCapability: String, CaseIterable, Codable, Sendable {
    case acp
    case permissions
    case diffs
    case cronCRUD
    case updateCheck
    case skillsToggle
    case toolsEnablePerPlatform
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
    /// (`if capabilities.has(.cronCRUD, in: version) { ... }`).
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
        // `hermes cron add/update/delete/...` CRUD verbs, first in v2026.3.17.
        .cronCRUD: HermesVersion(major: 0, minor: 3, patch: 0),
        // `hermes update --check` flag added by #10318, first in v2026.4.30.
        .updateCheck: HermesVersion(major: 0, minor: 12, patch: 0),
        // `hermes skills enable/disable` shipped via #642, first in v2026.3.12.
        .skillsToggle: HermesVersion(major: 0, minor: 2, patch: 0),
        // `hermes tools enable/disable/list` shipped via #1652, first in v2026.3.23.
        .toolsEnablePerPlatform: HermesVersion(major: 0, minor: 4, patch: 0),
    ]
}
