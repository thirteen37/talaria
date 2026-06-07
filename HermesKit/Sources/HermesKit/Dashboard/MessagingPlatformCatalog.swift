import Foundation

/// A curated, UI-free description of one messaging platform — friendly field
/// labels and an SF Symbol name overlaid on the messaging env vars Hermes
/// reports. Kept in HermesKit (string `systemImage`, no SwiftUI) so the
/// grouping logic is pure and unit-testable, mirroring ``KnownModelProviders``.
///
/// The catalog is a *presentation overlay only*: it never invents an env var.
/// A field whose `envVar` is absent from `GET /api/env` is simply dropped, and
/// platforms / vars not in the catalog still surface via prefix-based
/// auto-grouping (see ``groupMessagingPlatforms(envVars:catalog:gatewayPlatforms:)``),
/// so a new Hermes platform shows up without a Talaria release.
public struct MessagingPlatformCatalogEntry: Sendable, Equatable {
    /// One curated field: the underlying Hermes env-var name plus the friendly
    /// label and whether it's required for the platform to count as configured.
    public struct Field: Sendable, Equatable {
        public let envVar: String
        public let label: String
        public let required: Bool

        public init(envVar: String, label: String, required: Bool = false) {
            self.envVar = envVar
            self.label = label
            self.required = required
        }
    }

    /// Stable slug; also the group's identity in the UI.
    public let id: String
    public let displayName: String
    /// SF Symbol name (plain string — no SwiftUI dependency in HermesKit).
    public let systemImage: String
    /// Doc/setup link for the platform as a whole; per-field links come from
    /// each var's own `url`.
    public let docURL: String?
    /// Key into `DashboardStatus.gatewayPlatforms` for the live connection pill
    /// (the Hermes `Platform` enum value, e.g. `telegram`).
    public let statusKey: String
    /// Env-var name prefixes that also belong to this platform, so vars beyond
    /// the curated `fields` (e.g. `MATRIX_AUTO_THREAD`) attach here with a
    /// synthesized label instead of falling into a generic auto-group.
    public let envPrefixes: [String]
    /// Curated fields, in display order.
    public let fields: [Field]

    public init(
        id: String,
        displayName: String,
        systemImage: String,
        docURL: String?,
        statusKey: String,
        envPrefixes: [String],
        fields: [Field]
    ) {
        self.id = id
        self.displayName = displayName
        self.systemImage = systemImage
        self.docURL = docURL
        self.statusKey = statusKey
        self.envPrefixes = envPrefixes
        self.fields = fields
    }
}

/// One resolved platform card: the catalog metadata fused with the live
/// ``DashboardEnvVar`` values, the gateway connection state, and a derived
/// configured flag. Produced by ``groupMessagingPlatforms(envVars:catalog:gatewayPlatforms:)``.
public struct MessagingPlatformGroup: Sendable, Equatable, Identifiable {
    /// A field bound to its live env var, friendly label, and required flag.
    public struct Field: Sendable, Equatable, Identifiable {
        public let envVar: DashboardEnvVar
        public let label: String
        public let required: Bool

        public var id: String { envVar.name }

        public init(envVar: DashboardEnvVar, label: String, required: Bool) {
            self.envVar = envVar
            self.label = label
            self.required = required
        }
    }

    public let id: String
    public let displayName: String
    public let systemImage: String
    public let docURL: String?
    /// Live connection state from `gateway_platforms[statusKey]`, or nil when
    /// the gateway doesn't report this platform (status unknown / not running).
    public let connection: GatewayPlatform?
    /// True when every required field is set (or, for a platform with no
    /// required fields, when any field is set).
    public let isConfigured: Bool
    public let fields: [Field]

    public init(
        id: String,
        displayName: String,
        systemImage: String,
        docURL: String?,
        connection: GatewayPlatform?,
        isConfigured: Bool,
        fields: [Field]
    ) {
        self.id = id
        self.displayName = displayName
        self.systemImage = systemImage
        self.docURL = docURL
        self.connection = connection
        self.isConfigured = isConfigured
        self.fields = fields
    }
}

public enum MessagingPlatformCatalog {
    /// Seed catalog over Hermes' actual `OPTIONAL_ENV_VARS` (`category ==
    /// "messaging"`). `statusKey` is the Hermes `Platform` enum value. Array
    /// order is the card display order. Vars beyond the curated fields attach
    /// via `envPrefixes`; platforms with no env vars (config.yaml-only, e.g.
    /// Signal, WhatsApp, Email) are deliberately omitted — nothing to show.
    public static let entries: [MessagingPlatformCatalogEntry] = [
        MessagingPlatformCatalogEntry(
            id: "telegram",
            displayName: "Telegram",
            systemImage: "paperplane.fill",
            docURL: "https://t.me/BotFather",
            statusKey: "telegram",
            envPrefixes: ["TELEGRAM_"],
            fields: [
                .init(envVar: "TELEGRAM_BOT_TOKEN", label: "Bot Token", required: true),
                .init(envVar: "TELEGRAM_ALLOWED_USERS", label: "Allowed User IDs"),
                .init(envVar: "TELEGRAM_PROXY", label: "Proxy URL"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "discord",
            displayName: "Discord",
            systemImage: "gamecontroller.fill",
            docURL: "https://discord.com/developers/applications",
            statusKey: "discord",
            envPrefixes: ["DISCORD_"],
            fields: [
                .init(envVar: "DISCORD_BOT_TOKEN", label: "Bot Token", required: true),
                .init(envVar: "DISCORD_ALLOWED_USERS", label: "Allowed User IDs"),
                .init(envVar: "DISCORD_REPLY_TO_MODE", label: "Reply Mode"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "slack",
            displayName: "Slack",
            systemImage: "number.square.fill",
            docURL: "https://api.slack.com/apps",
            statusKey: "slack",
            envPrefixes: ["SLACK_"],
            fields: [
                .init(envVar: "SLACK_BOT_TOKEN", label: "Bot Token (xoxb-)", required: true),
                .init(envVar: "SLACK_APP_TOKEN", label: "App Token (xapp-)", required: true),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "mattermost",
            displayName: "Mattermost",
            systemImage: "message.fill",
            docURL: "https://mattermost.com/deploy/",
            statusKey: "mattermost",
            envPrefixes: ["MATTERMOST_"],
            fields: [
                .init(envVar: "MATTERMOST_URL", label: "Server URL", required: true),
                .init(envVar: "MATTERMOST_TOKEN", label: "Bot Token", required: true),
                .init(envVar: "MATTERMOST_ALLOWED_USERS", label: "Allowed User IDs"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "matrix",
            displayName: "Matrix",
            systemImage: "square.grid.3x3.fill",
            docURL: "https://matrix.org/ecosystem/servers/",
            statusKey: "matrix",
            envPrefixes: ["MATRIX_"],
            fields: [
                .init(envVar: "MATRIX_HOMESERVER", label: "Homeserver URL", required: true),
                .init(envVar: "MATRIX_ACCESS_TOKEN", label: "Access Token", required: true),
                .init(envVar: "MATRIX_USER_ID", label: "User ID"),
                .init(envVar: "MATRIX_ALLOWED_USERS", label: "Allowed User IDs"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "bluebubbles",
            displayName: "iMessage (BlueBubbles)",
            systemImage: "message.circle.fill",
            docURL: "https://bluebubbles.app/",
            statusKey: "bluebubbles",
            envPrefixes: ["BLUEBUBBLES_"],
            fields: [
                .init(envVar: "BLUEBUBBLES_SERVER_URL", label: "Server URL", required: true),
                .init(envVar: "BLUEBUBBLES_PASSWORD", label: "Server Password", required: true),
                .init(envVar: "BLUEBUBBLES_ALLOWED_USERS", label: "Allowed Addresses"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "qqbot",
            displayName: "QQ",
            systemImage: "bird.fill",
            docURL: "https://q.qq.com",
            statusKey: "qqbot",
            envPrefixes: ["QQ_", "QQBOT_"],
            fields: [
                .init(envVar: "QQ_APP_ID", label: "App ID", required: true),
                .init(envVar: "QQ_CLIENT_SECRET", label: "Client Secret", required: true),
                .init(envVar: "QQ_ALLOWED_USERS", label: "Allowed User IDs"),
                .init(envVar: "QQ_GROUP_ALLOWED_USERS", label: "Allowed Group IDs"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "homeassistant",
            displayName: "Home Assistant",
            systemImage: "house.fill",
            docURL: "https://hermes-agent.nousresearch.com/docs/user-guide/messaging/homeassistant",
            statusKey: "homeassistant",
            envPrefixes: ["HASS_"],
            fields: [
                .init(envVar: "HASS_TOKEN", label: "Long-Lived Access Token", required: true),
                .init(envVar: "HASS_URL", label: "Server URL"),
            ]
        ),
        MessagingPlatformCatalogEntry(
            id: "irc",
            displayName: "IRC",
            systemImage: "terminal.fill",
            docURL: nil,
            statusKey: "irc",
            envPrefixes: ["IRC_"],
            fields: [
                .init(envVar: "IRC_SERVER", label: "Server", required: true),
                .init(envVar: "IRC_CHANNEL", label: "Channel"),
                .init(envVar: "IRC_NICKNAME", label: "Nickname"),
                .init(envVar: "IRC_SERVER_PASSWORD", label: "Server Password"),
                .init(envVar: "IRC_NICKSERV_PASSWORD", label: "NickServ Password"),
            ]
        ),
    ]
}

/// Groups Hermes' messaging env vars into per-platform cards. Pure and
/// deterministic so it can be unit-tested without any HTTP or UI.
///
/// 1. Keep only `category == "messaging"`.
/// 2. For each catalog entry in order: bind its curated fields (dropping vars
///    Hermes doesn't report), then attach any not-yet-consumed prefix-matching
///    vars as extras with synthesized labels. Mark consumed; wire `connection`
///    from `gatewayPlatforms[statusKey]`; derive `isConfigured`. Emit only if
///    the platform ends up with ≥1 field.
/// 3. Auto-group every remaining messaging var by its first `_`-delimited
///    prefix, appended after the catalog groups in alphabetical order.
public func groupMessagingPlatforms(
    envVars: [DashboardEnvVar],
    catalog: [MessagingPlatformCatalogEntry] = MessagingPlatformCatalog.entries,
    gatewayPlatforms: [String: GatewayPlatform]
) -> [MessagingPlatformGroup] {
    let messaging = envVars.filter { $0.category == "messaging" }
    var index: [String: DashboardEnvVar] = [:]
    for envVar in messaging { index[envVar.name] = envVar }
    var consumed: Set<String> = []
    var groups: [MessagingPlatformGroup] = []

    for entry in catalog {
        var fields: [MessagingPlatformGroup.Field] = []

        // Curated fields first, in listed order, skipping vars Hermes doesn't
        // report (the catalog never invents a var).
        for field in entry.fields {
            guard let envVar = index[field.envVar], !consumed.contains(field.envVar) else { continue }
            consumed.insert(field.envVar)
            fields.append(.init(envVar: envVar, label: field.label, required: field.required))
        }

        // Prefix-matched extras (deterministic name order), each a non-required
        // field with a synthesized label from the var name minus its prefix.
        let extras = messaging
            .filter { envVar in
                !consumed.contains(envVar.name)
                    && entry.envPrefixes.contains { envVar.name.hasPrefix($0) }
            }
            .sorted { $0.name < $1.name }
        for envVar in extras {
            consumed.insert(envVar.name)
            let prefix = entry.envPrefixes
                .filter { envVar.name.hasPrefix($0) }
                .max { $0.count < $1.count } ?? ""
            fields.append(.init(
                envVar: envVar,
                label: friendlyMessagingLabel(envVar.name, strippingPrefix: prefix),
                required: false
            ))
        }

        guard !fields.isEmpty else { continue }
        groups.append(MessagingPlatformGroup(
            id: entry.id,
            displayName: entry.displayName,
            systemImage: entry.systemImage,
            docURL: entry.docURL,
            connection: gatewayPlatforms[entry.statusKey],
            isConfigured: messagingIsConfigured(fields),
            fields: fields
        ))
    }

    // Auto-group whatever's left by first `_` prefix (e.g. GATEWAY_*, API_*,
    // WEBHOOK_*), alphabetical, with a generic icon and a doc link borrowed
    // from the first var that carries one.
    let remaining = messaging.filter { !consumed.contains($0.name) }
    var buckets: [String: [DashboardEnvVar]] = [:]
    for envVar in remaining {
        let prefix = envVar.name.split(separator: "_").first.map(String.init) ?? envVar.name
        buckets[prefix, default: []].append(envVar)
    }
    let autoGroups = buckets
        .map { prefix, vars -> MessagingPlatformGroup in
            let sortedVars = vars.sorted { $0.name < $1.name }
            let fields = sortedVars.map { envVar in
                MessagingPlatformGroup.Field(
                    envVar: envVar,
                    label: friendlyMessagingLabel(envVar.name, strippingPrefix: prefix + "_"),
                    required: false
                )
            }
            let id = prefix.lowercased()
            return MessagingPlatformGroup(
                id: id,
                displayName: titleCasedMessagingToken(prefix),
                systemImage: "bubble.left.and.bubble.right",
                docURL: sortedVars.compactMap(\.url).first,
                connection: gatewayPlatforms[id],
                isConfigured: messagingIsConfigured(fields),
                fields: fields
            )
        }
        .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }

    groups.append(contentsOf: autoGroups)
    return groups
}

/// Configured = all required fields set, or (when nothing is required) any
/// field set. Shared by catalog and auto-group cards.
private func messagingIsConfigured(_ fields: [MessagingPlatformGroup.Field]) -> Bool {
    let required = fields.filter(\.required)
    if required.isEmpty {
        return fields.contains { $0.envVar.isSet }
    }
    return required.allSatisfy { $0.envVar.isSet }
}

/// Builds a friendly label from a var name by stripping a known prefix and
/// title-casing the rest (`MATRIX_AUTO_THREAD` − `MATRIX_` → "Auto Thread").
private func friendlyMessagingLabel(_ name: String, strippingPrefix prefix: String) -> String {
    var remainder = name
    if !prefix.isEmpty, remainder.hasPrefix(prefix) {
        remainder.removeFirst(prefix.count)
    }
    if remainder.isEmpty { remainder = name }
    return remainder
        .split(separator: "_")
        .map(titleCasedMessagingToken)
        .joined(separator: " ")
}

/// Common acronyms kept upper-cased so synthesized labels read naturally
/// ("Server URL", not "Server Url").
private let messagingAcronyms: Set<String> = ["ID", "URL", "API", "IRC", "QQ", "DM", "SMS", "TTL", "HMAC"]

private func titleCasedMessagingToken(_ token: some StringProtocol) -> String {
    let upper = token.uppercased()
    if messagingAcronyms.contains(upper) { return upper }
    return token.prefix(1).uppercased() + token.dropFirst().lowercased()
}
