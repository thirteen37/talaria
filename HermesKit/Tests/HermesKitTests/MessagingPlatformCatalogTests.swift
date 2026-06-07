import Foundation
import Testing
@testable import HermesKit

@Suite
struct MessagingPlatformCatalogTests {
    // MARK: - Builders

    private func envVar(
        _ name: String,
        category: String = "messaging",
        isSet: Bool = false,
        isPassword: Bool = false,
        url: String? = nil
    ) -> DashboardEnvVar {
        DashboardEnvVar(
            name: name,
            isSet: isSet,
            redactedValue: isSet ? "***" : nil,
            description: "\(name) description",
            url: url,
            category: category,
            isPassword: isPassword,
            tools: [],
            advanced: false
        )
    }

    private func platform(_ state: String) -> GatewayPlatform {
        GatewayPlatform(state: state, errorCode: nil, errorMessage: nil, updatedAt: nil)
    }

    private let catalog = MessagingPlatformCatalog.entries

    // MARK: - Tests

    @Test
    func explicitMatchKeepsCuratedLabelsInOrder() {
        let vars = [
            envVar("TELEGRAM_ALLOWED_USERS", isSet: true),
            envVar("TELEGRAM_BOT_TOKEN", isSet: true, isPassword: true),
        ]

        let groups = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])

        let telegram = try! #require(groups.first { $0.id == "telegram" })
        // Curated order wins over the input order (token before allowed users).
        #expect(telegram.fields.map(\.envVar.name) == ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS"])
        #expect(telegram.fields.map(\.label) == ["Bot Token", "Allowed User IDs"])
        #expect(telegram.fields.first?.required == true)
    }

    @Test
    func absentVarsAreDroppedNotInvented() {
        // Only the token is reported; the other curated Telegram fields vanish.
        let groups = groupMessagingPlatforms(
            envVars: [envVar("TELEGRAM_BOT_TOKEN", isSet: true, isPassword: true)],
            catalog: catalog,
            gatewayPlatforms: [:]
        )
        let telegram = try! #require(groups.first { $0.id == "telegram" })
        #expect(telegram.fields.map(\.envVar.name) == ["TELEGRAM_BOT_TOKEN"])
        // A platform with no reported vars at all is not emitted.
        #expect(groups.contains { $0.id == "discord" } == false)
    }

    @Test
    func prefixExtraAttachesToKnownPlatformWithSynthesizedLabel() {
        let vars = [
            envVar("MATRIX_HOMESERVER", isSet: true),
            envVar("MATRIX_ACCESS_TOKEN", isSet: true, isPassword: true),
            envVar("MATRIX_AUTO_THREAD", isSet: true), // not a curated field
        ]

        let groups = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])
        let matrix = try! #require(groups.first { $0.id == "matrix" })

        // The extra attaches after the curated fields, non-required, with a
        // synthesized label (prefix stripped, title-cased).
        let extra = try! #require(matrix.fields.first { $0.envVar.name == "MATRIX_AUTO_THREAD" })
        #expect(extra.label == "Auto Thread")
        #expect(extra.required == false)
        // It is NOT split into a generic auto-group.
        #expect(groups.contains { $0.id == "matrix" } && groups.filter { $0.id == "matrix" }.count == 1)
    }

    @Test
    func uncataloguedVarAutoGroupsByPrefix() {
        let vars = [
            envVar("WEBHOOK_SECRET", isSet: true, isPassword: true),
            envVar("WEBHOOK_PORT", isSet: false, url: "https://example.com/webhooks"),
        ]

        let groups = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])

        let webhook = try! #require(groups.first { $0.id == "webhook" })
        #expect(webhook.displayName == "Webhook")
        #expect(webhook.systemImage == "bubble.left.and.bubble.right")
        // Fields name-sorted; labels are the prefix-stripped, title-cased names.
        #expect(webhook.fields.map(\.envVar.name) == ["WEBHOOK_PORT", "WEBHOOK_SECRET"])
        #expect(webhook.fields.map(\.label) == ["Port", "Secret"])
        // docURL borrowed from the first var that carries one.
        #expect(webhook.docURL == "https://example.com/webhooks")
    }

    @Test
    func isConfiguredOnlyWhenRequiredSet() {
        // Token set, but Slack also requires the app token → not configured.
        let partial = groupMessagingPlatforms(
            envVars: [
                envVar("SLACK_BOT_TOKEN", isSet: true, isPassword: true),
                envVar("SLACK_APP_TOKEN", isSet: false, isPassword: true),
            ],
            catalog: catalog,
            gatewayPlatforms: [:]
        )
        #expect(try! #require(partial.first { $0.id == "slack" }).isConfigured == false)

        // Both required tokens set → configured.
        let full = groupMessagingPlatforms(
            envVars: [
                envVar("SLACK_BOT_TOKEN", isSet: true, isPassword: true),
                envVar("SLACK_APP_TOKEN", isSet: true, isPassword: true),
            ],
            catalog: catalog,
            gatewayPlatforms: [:]
        )
        #expect(try! #require(full.first { $0.id == "slack" }).isConfigured == true)
    }

    @Test
    func autoGroupConfiguredWhenAnyFieldSet() {
        let groups = groupMessagingPlatforms(
            envVars: [
                envVar("GATEWAY_ALLOW_ALL_USERS", isSet: false),
                envVar("GATEWAY_PROXY_KEY", isSet: true, isPassword: true),
            ],
            catalog: catalog,
            gatewayPlatforms: [:]
        )
        // No required fields in an auto-group → any-set counts as configured.
        #expect(try! #require(groups.first { $0.id == "gateway" }).isConfigured == true)
    }

    @Test
    func connectionWiredFromStatusKey() {
        let groups = groupMessagingPlatforms(
            envVars: [envVar("TELEGRAM_BOT_TOKEN", isSet: true, isPassword: true)],
            catalog: catalog,
            gatewayPlatforms: ["telegram": platform("connected")]
        )
        #expect(try! #require(groups.first { $0.id == "telegram" }).connection?.state == "connected")
    }

    @Test
    func nonMessagingVarsAreExcluded() {
        let groups = groupMessagingPlatforms(
            envVars: [
                envVar("ANTHROPIC_API_KEY", category: "provider", isSet: true, isPassword: true),
                envVar("HERMES_LOG_LEVEL", category: "setting", isSet: true),
                envVar("TELEGRAM_BOT_TOKEN", isSet: true, isPassword: true),
            ],
            catalog: catalog,
            gatewayPlatforms: [:]
        )
        // Only the messaging var produces a group.
        #expect(groups.count == 1)
        #expect(groups.first?.id == "telegram")
    }

    @Test
    func catalogGroupsPrecedeAlphabeticalAutoGroups() {
        let vars = [
            envVar("WEBHOOK_SECRET", isSet: true, isPassword: true),  // auto: "webhook"
            envVar("API_SERVER_PORT", isSet: true),                   // auto: "api"
            envVar("TELEGRAM_BOT_TOKEN", isSet: true, isPassword: true), // catalog
        ]

        let groups = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])

        // Catalog (telegram) first; auto-groups after, alphabetical (API, Webhook).
        #expect(groups.map(\.id) == ["telegram", "api", "webhook"])
        #expect(groups.first { $0.id == "api" }?.displayName == "API")
    }

    @Test
    func deterministicAcrossRuns() {
        let vars = [
            envVar("DISCORD_BOT_TOKEN", isSet: true, isPassword: true),
            envVar("TELEGRAM_BOT_TOKEN", isSet: true, isPassword: true),
            envVar("WEBHOOK_SECRET", isSet: true, isPassword: true),
            envVar("API_SERVER_PORT", isSet: true),
        ]
        let first = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])
        let second = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])
        #expect(first == second)
        #expect(first.map(\.id) == ["telegram", "discord", "api", "webhook"])
    }

    @Test
    func homeAssistantGroupsUnderCuratedKeyNotHassAutoGroup() {
        let vars = [
            envVar("HASS_TOKEN", isSet: true, isPassword: true),
            envVar("HASS_URL", isSet: true),
        ]

        let groups = groupMessagingPlatforms(
            envVars: vars,
            catalog: catalog,
            gatewayPlatforms: ["homeassistant": platform("connected")]
        )

        // Exactly one Home Assistant card, keyed to the gateway status key.
        let ha = try! #require(groups.first { $0.id == "homeassistant" })
        #expect(ha.displayName == "Home Assistant")
        #expect(ha.fields.map(\.envVar.name) == ["HASS_TOKEN", "HASS_URL"])
        #expect(ha.fields.map(\.label) == ["Long-Lived Access Token", "Server URL"])
        #expect(ha.fields.first?.required == true)
        // Connection pill wires from gateway_platforms["homeassistant"].
        #expect(ha.connection?.state == "connected")
        // No stray "hass" auto-group / "Hass" card.
        #expect(groups.contains { $0.id == "hass" } == false)
        #expect(groups.contains { $0.displayName == "Hass" } == false)
    }

    @Test
    func qqUsesBothPrefixesForExtras() {
        let vars = [
            envVar("QQ_APP_ID", isSet: true),
            envVar("QQ_CLIENT_SECRET", isSet: true, isPassword: true),
            envVar("QQBOT_HOME_CHANNEL", isSet: true), // QQBOT_ prefix, not QQ_
        ]
        let groups = groupMessagingPlatforms(envVars: vars, catalog: catalog, gatewayPlatforms: [:])
        let qq = try! #require(groups.first { $0.id == "qqbot" })
        // The QQBOT_ var attaches here, not as a separate auto-group.
        #expect(qq.fields.contains { $0.envVar.name == "QQBOT_HOME_CHANNEL" })
        #expect(groups.allSatisfy { $0.id != "qqbot" || $0.fields.count == 3 })
        #expect(groups.contains { $0.displayName == "Qqbot" } == false)
    }
}
