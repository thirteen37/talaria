import Foundation

/// Which config dotpaths the sync surface curates by default, and which are
/// never push candidates.
public enum ConfigSyncScope {
    /// Provider/model sections shown by default (the "Show all differences"
    /// toggle reveals the rest). A dotpath is curated when it equals one of these
    /// or is nested beneath it (`<prefix>.…`) — note `model_context_length` is
    /// *not* curated by the `model` prefix because it isn't `model.…`.
    public static let curatedPrefixes = ["model", "providers", "custom_providers", "fallback_providers", "auxiliary"]

    public static func isCurated(dotpath: String) -> Bool {
        curatedPrefixes.contains { dotpath == $0 || dotpath.hasPrefix($0 + ".") }
    }

    /// `auxiliary.<slot>.base_url` is a decoupled, frequently-stale per-slot
    /// override (Talaria clears it on Change/Reset elsewhere). Pushing it would
    /// propagate staleness, so it's hard-excluded from every push payload — even
    /// when "Show all differences" is on. It still displays as a read-only row.
    public static func isExcludedFromPush(dotpath: String) -> Bool {
        let parts = dotpath.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.first == "auxiliary" && parts.last == "base_url"
    }
}

/// One config dotpath that differs between the default profile and a named
/// profile.
public struct ConfigDriftItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case changed
        case missingInProfile
    }

    public let dotpath: String
    /// The default profile's value — the push payload for this row.
    public let defaultValue: ConfigValue
    /// The named profile's current value, or nil when the key is absent there.
    public let profileValue: ConfigValue?
    public let kind: Kind
    public let isCurated: Bool
    /// Schema category for grouping, or `other` for unmodeled keys.
    public let category: String
    /// False for the `auxiliary.*.base_url` exclusion and for schema-typed
    /// number/boolean values that didn't coerce (a `.raw` mismatch) — those rows
    /// display read-only.
    public let isPushable: Bool

    public var id: String { dotpath }

    public init(
        dotpath: String,
        defaultValue: ConfigValue,
        profileValue: ConfigValue?,
        kind: Kind,
        isCurated: Bool,
        category: String,
        isPushable: Bool
    ) {
        self.dotpath = dotpath
        self.defaultValue = defaultValue
        self.profileValue = profileValue
        self.kind = kind
        self.isCurated = isCurated
        self.category = category
        self.isPushable = isPushable
    }
}

/// A config dotpath present only in the named profile — display-only (v1 never
/// deletes from a target).
public struct ConfigExtraItem: Equatable, Sendable, Identifiable {
    public let dotpath: String
    public let profileValue: ConfigValue
    public let isCurated: Bool

    public var id: String { dotpath }

    public init(dotpath: String, profileValue: ConfigValue, isCurated: Bool) {
        self.dotpath = dotpath
        self.profileValue = profileValue
        self.isCurated = isCurated
    }
}

/// Config-level drift for one named profile relative to the default profile.
public struct ProfileConfigDrift: Equatable, Sendable {
    public let profileName: String
    /// Differing dotpaths (changed + missing-in-profile), sorted by dotpath.
    public let items: [ConfigDriftItem]
    /// Named-only dotpaths, display-only.
    public let extras: [ConfigExtraItem]

    public init(profileName: String, items: [ConfigDriftItem], extras: [ConfigExtraItem]) {
        self.profileName = profileName
        self.items = items
        self.extras = extras
    }

    public var curatedItems: [ConfigDriftItem] { items.filter(\.isCurated) }
    public var curatedCount: Int { curatedItems.count }
    public var allCount: Int { items.count }
    public var isInSync: Bool { items.isEmpty }

    /// The non-destructive edit map to merge into a fresh `GET /api/config` and
    /// PUT. Includes only pushable rows; `curatedOnly` restricts to the curated
    /// provider/model sections. Equivalent to
    /// ``ProfileConfigForm/edits(from:base:schema:)`` for the full set.
    public func pushPayload(curatedOnly: Bool) -> [String: ConfigValue] {
        var result: [String: ConfigValue] = [:]
        for item in items where item.isPushable && (!curatedOnly || item.isCurated) {
            result[item.dotpath] = item.defaultValue
        }
        return result
    }

    /// Push payload restricted to an explicit set of dotpaths (per-row / partial
    /// selection), keeping only pushable rows.
    public func pushPayload(dotpaths: Set<String>) -> [String: ConfigValue] {
        var result: [String: ConfigValue] = [:]
        for item in items where item.isPushable && dotpaths.contains(item.dotpath) {
            result[item.dotpath] = item.defaultValue
        }
        return result
    }
}

/// Computes config drift between the default profile (source of truth) and a
/// named profile, from `JSONValue` documents bridged from raw `config.yaml`.
/// Pure — reuses ``ProfileConfigForm``'s flatten/lookup/coercion so the push
/// payload matches the structured editor's non-destructive merge exactly.
public enum ProfileConfigDriftPlanner {
    public static func drift(
        profileName: String,
        defaultConfig: JSONValue,
        profileConfig: JSONValue,
        schema: DashboardConfigSchema?
    ) -> ProfileConfigDrift {
        var items: [ConfigDriftItem] = []
        for (dotpath, defaultLeaf) in ProfileConfigForm.flatten(defaultConfig) {
            let profileLeaf = ProfileConfigForm.lookup(dotpath, in: profileConfig)
            guard profileLeaf != defaultLeaf else { continue }   // in sync at this leaf
            let type = schema?.field(for: dotpath)?.type
            let defaultValue = ProfileConfigForm.configValue(from: defaultLeaf, schemaType: type)
            let profileValue = profileLeaf.map { ProfileConfigForm.configValue(from: $0, schemaType: type) }
            items.append(ConfigDriftItem(
                dotpath: dotpath,
                defaultValue: defaultValue,
                profileValue: profileValue,
                kind: profileLeaf == nil ? .missingInProfile : .changed,
                isCurated: ConfigSyncScope.isCurated(dotpath: dotpath),
                category: schema?.field(for: dotpath)?.category ?? ProfileConfigForm.otherCategoryName,
                isPushable: isPushable(dotpath: dotpath, type: type, value: defaultValue)
            ))
        }
        items.sort { $0.dotpath < $1.dotpath }

        var extras: [ConfigExtraItem] = []
        for (dotpath, profileLeaf) in ProfileConfigForm.flatten(profileConfig)
        where ProfileConfigForm.lookup(dotpath, in: defaultConfig) == nil {
            let type = schema?.field(for: dotpath)?.type
            extras.append(ConfigExtraItem(
                dotpath: dotpath,
                profileValue: ProfileConfigForm.configValue(from: profileLeaf, schemaType: type),
                isCurated: ConfigSyncScope.isCurated(dotpath: dotpath)
            ))
        }
        extras.sort { $0.dotpath < $1.dotpath }

        return ProfileConfigDrift(profileName: profileName, items: items, extras: extras)
    }

    /// Mirrors ``ProfileConfigForm/edits(from:base:schema:)``'s drop rule (a
    /// schema-typed number/boolean that stays `.raw` is invalid) plus the
    /// `auxiliary.*.base_url` hard-exclusion.
    private static func isPushable(dotpath: String, type: ConfigFieldType?, value: ConfigValue) -> Bool {
        if ConfigSyncScope.isExcludedFromPush(dotpath: dotpath) { return false }
        if let type, type == .number || type == .boolean, case .raw = value { return false }
        return true
    }
}
