import Foundation
import Testing
@testable import HermesKit

@Suite
struct HindsightEndpointTests {
    // MARK: - bank_id template resolution (mirrors Hermes _resolve_bank_id_template)

    @Test
    func bankIDFallsBackWhenTemplateEmpty() {
        let id = HindsightEndpoint.resolveBankID(template: "", fallback: "hermes")
        #expect(id == "hermes")
    }

    @Test
    func bankIDSubstitutesProfilePlaceholder() {
        let id = HindsightEndpoint.resolveBankID(template: "{profile}", fallback: "hermes", profile: "work")
        #expect(id == "work")
    }

    @Test
    func bankIDCollapsesMissingDynamicPlaceholders() {
        // `hermes-{user}` with no user → trailing separator stripped → "hermes"
        let id = HindsightEndpoint.resolveBankID(template: "hermes-{user}", fallback: "hermes")
        #expect(id == "hermes")
    }

    @Test
    func bankIDSanitizesUnsafeCharacters() {
        let id = HindsightEndpoint.resolveBankID(template: "{profile}", fallback: "hermes", profile: "My Work!!")
        #expect(id == "My-Work")
    }

    @Test
    func bankIDFallsBackOnInvalidTemplate() {
        // An unknown placeholder makes str.format-style rendering fail → fallback.
        let id = HindsightEndpoint.resolveBankID(template: "{nope}", fallback: "hermes")
        #expect(id == "hermes")
    }

    // MARK: - config.json decoding

    @Test
    func configDecodesAPIKeyAndBankAliases() throws {
        let json = Data(#"""
        { "mode": "cloud", "api_key": "k1", "bank_id": "myb" }
        """#.utf8)
        let config = try JSONDecoder().decode(HindsightConfig.self, from: json)
        #expect(config.apiKey == "k1")
        #expect(config.bankID == "myb")
        #expect(config.mode == "cloud")
    }

    @Test
    func configReadsNestedBanksBankID() throws {
        let json = Data(#"""
        { "mode": "local_embedded", "banks": { "hermes": { "bankId": "nested" } } }
        """#.utf8)
        let config = try JSONDecoder().decode(HindsightConfig.self, from: json)
        #expect(config.bankID == nil)
        #expect(config.banksBankID == "nested")
    }

    // MARK: - metadata.json decoding

    @Test
    func metadataResolvesProfilePort() throws {
        let json = Data(#"""
        { "version": 1, "profiles": { "talaria-test": { "port": 9123, "created_at": "x" } } }
        """#.utf8)
        let meta = try JSONDecoder().decode(HindsightProfileMetadata.self, from: json)
        #expect(meta.port(forProfile: "talaria-test") == 9123)
        #expect(meta.port(forProfile: "missing") == nil)
    }

    // MARK: - endpoint resolution

    @Test
    func localEmbeddedDefaultProfileUsesPort8888() throws {
        let config = HindsightConfig(mode: "local_embedded", profile: "default")
        let endpoint = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: nil)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:8888")
        #expect(endpoint.apiKey == nil)
        #expect(endpoint.tenant == "default")
        #expect(endpoint.bankID == "hermes")
    }

    @Test
    func localEmbeddedNamedProfileReadsPortFromMetadata() throws {
        let config = HindsightConfig(mode: "local_embedded", profile: "talaria-test", bankID: "hermes")
        let meta = HindsightProfileMetadata(profiles: ["talaria-test": 9123])
        let endpoint = try HindsightEndpoint.make(config: config, metadata: meta, envAPIKey: nil)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:9123")
        #expect(endpoint.apiKey == nil)
    }

    @Test
    func localEmbeddedNormalizesLegacyLocalMode() throws {
        // Hermes maps the legacy "local" mode onto "local_embedded".
        let config = HindsightConfig(mode: "local", profile: "default")
        let endpoint = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: nil)
        #expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:8888")
    }

    @Test
    func localEmbeddedMissingPortThrows() {
        let config = HindsightConfig(mode: "local_embedded", profile: "hermes")
        let meta = HindsightProfileMetadata(profiles: [:])
        #expect(throws: HindsightEndpointError.self) {
            _ = try HindsightEndpoint.make(config: config, metadata: meta, envAPIKey: nil)
        }
    }

    @Test
    func cloudUsesAPIURLAndKey() throws {
        let config = HindsightConfig(mode: "cloud", apiKey: "secret", apiURL: "https://api.hindsight.vectorize.io", bankID: "hermes")
        let endpoint = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: nil)
        #expect(endpoint.baseURL.absoluteString == "https://api.hindsight.vectorize.io")
        #expect(endpoint.apiKey == "secret")
    }

    @Test
    func cloudFallsBackToEnvKeyAndDefaultURL() throws {
        let config = HindsightConfig(mode: "cloud")
        let endpoint = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: "envkey")
        #expect(endpoint.baseURL.absoluteString == "https://api.hindsight.vectorize.io")
        #expect(endpoint.apiKey == "envkey")
    }

    @Test
    func remoteEmbeddedIsUnsupported() {
        // A remote profile's embedded daemon listens on the *remote* loopback;
        // browsing it from the local app needs an SSH tunnel (v1 follow-on).
        let config = HindsightConfig(mode: "local_embedded", profile: "default")
        #expect(throws: HindsightEndpointError.remoteEmbeddedUnsupported) {
            _ = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: nil, isRemote: true)
        }
    }

    @Test
    func remoteCloudStillResolves() throws {
        // Cloud is reachable from anywhere, so a remote profile can browse it.
        let config = HindsightConfig(mode: "cloud", apiKey: "k", bankID: "hermes")
        let endpoint = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: nil, isRemote: true)
        #expect(endpoint.baseURL.absoluteString == "https://api.hindsight.vectorize.io")
        #expect(endpoint.apiKey == "k")
    }

    @Test
    func bankTemplateOverridesStaticBankID() throws {
        let config = HindsightConfig(mode: "local_embedded", profile: "default", bankID: "hermes", bankIDTemplate: "{profile}")
        let endpoint = try HindsightEndpoint.make(config: config, metadata: nil, envAPIKey: nil, profilePlaceholder: "work")
        #expect(endpoint.bankID == "work")
    }
}
