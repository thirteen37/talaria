import Foundation

/// Maps an installed hub skill (a `hermes skills list` row) back to a Skills Hub
/// **install identifier**, so a skill missing from a named profile can be
/// installed by the same identifier the default profile used.
///
/// `hermes skills list` doesn't print the install identifier; it prints a
/// display `name` (which for a skills-sh install *is* the identifier) plus a
/// `source` origin. Recovering the identifier is therefore a best-effort cascade
/// over the public catalog:
///   1. the installed name is itself a catalog identifier (the
///      `skills-sh/github/foo-bar` shape);
///   2. an exact case-insensitive `(name, source)` catalog match;
///   3. the name is unique across the whole catalog (source disagreement is
///      tolerated — origins drift);
///   4. otherwise `nil` — the skill can't be safely installed and the UI shows a
///      "install it manually" blocker rather than guessing.
public struct HubSkillIdentifierIndex: Sendable {
    /// Lowercased identifier → canonical identifier.
    private let identifiersByLowercased: [String: String]
    /// "name|source" lowercased → identifier (last wins, but identifiers are
    /// stable+unique so collisions here are vanishingly rare).
    private let bySourcedName: [String: String]
    /// Lowercased name → the identifiers carrying that name, for the uniqueness
    /// check.
    private let identifiersByName: [String: [String]]

    public init(catalog: [HubCatalogSkill]) {
        var identifiersByLowercased: [String: String] = [:]
        var bySourcedName: [String: String] = [:]
        var identifiersByName: [String: [String]] = [:]
        for skill in catalog {
            identifiersByLowercased[skill.identifier.lowercased()] = skill.identifier
            bySourcedName["\(skill.name.lowercased())|\(skill.source.lowercased())"] = skill.identifier
            identifiersByName[skill.name.lowercased(), default: []].append(skill.identifier)
        }
        self.identifiersByLowercased = identifiersByLowercased
        self.bySourcedName = bySourcedName
        self.identifiersByName = identifiersByName
    }

    public func identifier(for skill: InstalledHubSkill) -> String? {
        // 1. Exact (name, source) match — the most specific, and tried FIRST so a
        //    bare-name installed skill (e.g. official `1password`) resolves to its
        //    own source's identifier (`official/security/1password`) rather than a
        //    *different* source whose identifier happens to equal that bare name
        //    (the Nous index has clawhub entries whose identifier IS the bare
        //    name, which the name-is-identifier step below would otherwise grab).
        if let id = bySourcedName["\(skill.name.lowercased())|\(skill.source.lowercased())"] {
            return id
        }
        // 2. The installed name is itself a catalog identifier — the skills-sh
        //    shape, where `skills list` prints the full identifier as the name.
        if let canonical = identifiersByLowercased[skill.name.lowercased()] {
            return canonical
        }
        // 3. The name is unique across the whole catalog.
        if let ids = identifiersByName[skill.name.lowercased()], ids.count == 1 {
            return ids[0]
        }
        return nil
    }
}

/// One skill that differs between the default profile and a named profile.
public struct SkillDriftItem: Equatable, Sendable, Identifiable {
    /// Why a missing skill can't be installed automatically.
    public enum Blocker: Equatable, Sendable {
        /// The default skill's name didn't resolve to a catalog identifier.
        case identifierNotFound
        /// The catalog index couldn't be loaded, so no identifier could be
        /// resolved for any skill.
        case catalogUnavailable
    }

    public enum Kind: Equatable, Sendable {
        /// The skill is absent from the named profile. `identifier` is the
        /// install id when resolvable (then `blocker` is nil); otherwise
        /// `identifier` is nil and `blocker` explains why.
        case missing(identifier: String?, blocker: Blocker?)
        /// The skill is present in the named profile but `hermes skills check`
        /// reports an upstream update is available there.
        case outdated
    }

    /// The default profile's skill name (the display label and the `update`
    /// target).
    public let name: String
    /// The default skill's `source` origin, for display.
    public let source: String
    /// The default skill's category folder (e.g. `creative`), nil/empty when
    /// uncategorized — needed to locate `skills/<category>/<name>/SKILL.md`.
    public let category: String?
    public let kind: Kind

    public var id: String { name }

    public init(name: String, source: String, category: String?, kind: Kind) {
        self.name = name
        self.source = source
        self.category = category
        self.kind = kind
    }

    /// The identifier to `hermes skills install`, when this is an installable
    /// missing skill.
    public var installIdentifier: String? {
        if case .missing(let identifier, _) = kind { return identifier }
        return nil
    }

    /// Whether a push button should be enabled (installable-missing or outdated).
    public var isActionable: Bool {
        switch kind {
        case .missing(let identifier, _):
            return identifier != nil
        case .outdated:
            return true
        }
    }
}

/// Skill-level drift for one named profile relative to the default profile.
public struct ProfileSkillsDrift: Equatable, Sendable {
    public let profileName: String
    /// Out-of-sync skills, in the default profile's listing order.
    public let items: [SkillDriftItem]
    /// Hub skills present only in the named profile — display-only (v1 never
    /// deletes from a target).
    public let extras: [InstalledHubSkill]

    public init(profileName: String, items: [SkillDriftItem], extras: [InstalledHubSkill]) {
        self.profileName = profileName
        self.items = items
        self.extras = extras
    }

    public var missingCount: Int {
        items.filter { if case .missing = $0.kind { return true } else { return false } }.count
    }

    public var outdatedCount: Int {
        items.filter { $0.kind == .outdated }.count
    }

    public var isInSync: Bool { items.isEmpty }
}

/// Computes skill drift between the default profile (source of truth) and a
/// named profile. Pure — the caller supplies the three `hermes skills`
/// snapshots and the catalog index.
public enum ProfileSkillsDriftPlanner {
    public static func drift(
        profileName: String,
        defaultSkills: [InstalledHubSkill],
        profileSkills: [InstalledHubSkill],
        updateStatuses: [SkillUpdateStatus],
        index: HubSkillIdentifierIndex?
    ) -> ProfileSkillsDrift {
        // Presence is by name across the named profile's *full* listing (any
        // source) — a name-colliding local skill counts as present so we never
        // clobber it.
        let presentByName: [String: InstalledHubSkill] = Dictionary(
            profileSkills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let updateByName: [String: SkillUpdateStatus] = Dictionary(
            updateStatuses.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var items: [SkillDriftItem] = []
        for skill in defaultSkills where skill.isHubManaged {
            if let present = presentByName[skill.name] {
                // Present — outdated only if the named row is itself hub-managed
                // and its update check flags an available update. Enabled state
                // is ignored.
                if present.isHubManaged, updateByName[skill.name]?.updateAvailable == true {
                    items.append(SkillDriftItem(name: skill.name, source: skill.source, category: skill.category, kind: .outdated))
                }
            } else {
                let (identifier, blocker) = resolveInstall(for: skill, index: index)
                items.append(SkillDriftItem(
                    name: skill.name,
                    source: skill.source,
                    category: skill.category,
                    kind: .missing(identifier: identifier, blocker: blocker)
                ))
            }
        }

        let defaultNames = Set(defaultSkills.map(\.name))
        let extras = profileSkills.filter { $0.isHubManaged && !defaultNames.contains($0.name) }

        return ProfileSkillsDrift(profileName: profileName, items: items, extras: extras)
    }

    /// Default-profile skills that are local (not hub-managed, not builtin) and
    /// therefore can't be propagated — surfaced as a footnote so the user knows
    /// they were intentionally skipped.
    public static func unsyncableLocalSkills(defaultSkills: [InstalledHubSkill]) -> [InstalledHubSkill] {
        defaultSkills.filter { $0.source.lowercased() == "local" }
    }

    private static func resolveInstall(
        for skill: InstalledHubSkill,
        index: HubSkillIdentifierIndex?
    ) -> (identifier: String?, blocker: SkillDriftItem.Blocker?) {
        guard let index else { return (nil, .catalogUnavailable) }
        if let identifier = index.identifier(for: skill) { return (identifier, nil) }
        return (nil, .identifierNotFound)
    }
}
