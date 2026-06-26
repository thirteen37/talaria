import Foundation

/// Errors raised while resolving a Hindsight endpoint from Hermes config.
public enum HindsightEndpointError: Error, Equatable, Sendable {
    /// A `local_embedded` named profile has no port in `~/.hindsight/profiles/metadata.json`
    /// (the daemon for that profile was never created / has never run).
    case embeddedProfilePortUnknown(profile: String)
    /// The configured mode isn't one Talaria can browse (e.g. `disabled`).
    case unsupportedMode(String)
    /// A resolved base URL string couldn't be parsed.
    case invalidBaseURL(String)
    /// The profile is remote and uses a `local_embedded` daemon, which listens on
    /// the *remote* loopback — unreachable from the local app without an SSH
    /// tunnel to its port (a documented v1 follow-on).
    case remoteEmbeddedUnsupported
}

/// The Hermes-side Hindsight provider config (`$HERMES_HOME/hindsight/config.json`).
///
/// Decoding is tolerant of the key aliases Hermes accepts (`apiKey`/`api_key`,
/// `bank_id`, nested `banks.hermes.bankId`) and treats every field as optional.
public struct HindsightConfig: Equatable, Sendable {
    public var mode: String
    public var apiKey: String?
    public var apiURL: String?
    public var bankID: String?
    public var bankIDTemplate: String?
    /// The Hindsight *embedded* profile name (default `"hermes"`); only the literal
    /// `"default"` profile maps to the fixed port 8888.
    public var profile: String?
    /// `banks.hermes.bankId`, a secondary source for the static bank id.
    public var banksBankID: String?

    public init(
        mode: String = "cloud",
        apiKey: String? = nil,
        apiURL: String? = nil,
        profile: String? = nil,
        bankID: String? = nil,
        bankIDTemplate: String? = nil,
        banksBankID: String? = nil
    ) {
        self.mode = mode
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.bankID = bankID
        self.bankIDTemplate = bankIDTemplate
        self.profile = profile
        self.banksBankID = banksBankID
    }
}

extension HindsightConfig: Decodable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func str(_ key: String) -> String? {
            guard let k = DynamicKey(stringValue: key) else { return nil }
            let value = try? c.decode(String.self, forKey: k)
            return (value?.isEmpty == false) ? value : nil
        }

        let mode = str("mode") ?? "cloud"
        let apiKey = str("apiKey") ?? str("api_key")
        let apiURL = str("api_url")
        let bankID = str("bank_id")
        let bankIDTemplate = str("bank_id_template")
        let profile = str("profile")

        // banks.hermes.bankId (nested)
        var banksBankID: String?
        if let banksKey = DynamicKey(stringValue: "banks"),
           let banks = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: banksKey),
           let hermesKey = DynamicKey(stringValue: "hermes"),
           let hermes = try? banks.nestedContainer(keyedBy: DynamicKey.self, forKey: hermesKey),
           let bankIdKey = DynamicKey(stringValue: "bankId") {
            banksBankID = try? hermes.decode(String.self, forKey: bankIdKey)
        }

        self.init(
            mode: mode,
            apiKey: apiKey,
            apiURL: apiURL,
            profile: profile,
            bankID: bankID,
            bankIDTemplate: bankIDTemplate,
            banksBankID: banksBankID
        )
    }
}

/// `~/.hindsight/profiles/metadata.json` — maps each embedded profile name to its daemon port.
public struct HindsightProfileMetadata: Equatable, Sendable {
    private let ports: [String: Int]

    public init(profiles: [String: Int]) { self.ports = profiles }

    public func port(forProfile name: String) -> Int? { ports[name] }
}

extension HindsightProfileMetadata: Decodable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private struct ProfileEntry: Decodable { let port: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var ports: [String: Int] = [:]
        if let profilesKey = DynamicKey(stringValue: "profiles"),
           let profiles = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: profilesKey) {
            for key in profiles.allKeys {
                if let entry = try? profiles.decode(ProfileEntry.self, forKey: key), let port = entry.port {
                    ports[key.stringValue] = port
                }
            }
        }
        self.init(profiles: ports)
    }
}

/// A resolved, ready-to-use Hindsight REST target.
public struct HindsightEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let tenant: String
    public let bankID: String
    public let apiKey: String?

    public init(baseURL: URL, tenant: String = "default", bankID: String, apiKey: String?) {
        self.baseURL = baseURL
        self.tenant = tenant
        self.bankID = bankID
        self.apiKey = apiKey
    }

    /// Build an ``HindsightAPIClient`` for this endpoint.
    public func makeClient(http: any DashboardHTTP = URLSession.shared) -> HindsightAPIClient {
        HindsightAPIClient(baseURL: baseURL, apiKey: apiKey, tenant: tenant, http: http)
    }

    // MARK: - Resolution

    private static let cloudDefaultURL = "https://api.hindsight.vectorize.io"
    private static let localDefaultURL = "http://localhost:8888"
    private static let embeddedDefaultPort = 8888

    /// Resolve a `{ baseURL, tenant, bankID, apiKey? }` endpoint from Hermes' Hindsight config.
    ///
    /// - `metadata` is only consulted for `local_embedded` named profiles.
    /// - `envAPIKey` is the `HINDSIGHT_API_KEY` fallback for cloud / local_external.
    /// - `profilePlaceholder` feeds the `{profile}` slot of a `bank_id_template`.
    public static func make(
        config: HindsightConfig,
        metadata: HindsightProfileMetadata?,
        envAPIKey: String?,
        profilePlaceholder: String = "",
        isRemote: Bool = false
    ) throws -> HindsightEndpoint {
        let mode = normalizeMode(config.mode)
        let fallbackBank = config.bankID ?? config.banksBankID ?? "hermes"
        let bankID = resolveBankID(
            template: config.bankIDTemplate ?? "",
            fallback: fallbackBank,
            profile: profilePlaceholder
        )

        switch mode {
        case "local_embedded":
            // The embedded daemon binds the *host's* loopback. For a remote
            // profile that's the remote box; `make` can't reach it directly, so
            // it refuses here — the resolver handles remote embedded by opening a
            // tunnel (see `HindsightEndpointResolver`).
            if isRemote {
                throw HindsightEndpointError.remoteEmbeddedUnsupported
            }
            let port = try embeddedPort(config: config, metadata: metadata)
            guard let url = URL(string: "http://127.0.0.1:\(port)") else {
                throw HindsightEndpointError.invalidBaseURL("http://127.0.0.1:\(port)")
            }
            return HindsightEndpoint(baseURL: url, tenant: "default", bankID: bankID, apiKey: nil)

        case "cloud", "local_external":
            let urlString = config.apiURL ?? (mode == "cloud" ? cloudDefaultURL : localDefaultURL)
            guard let url = URL(string: urlString) else {
                throw HindsightEndpointError.invalidBaseURL(urlString)
            }
            return HindsightEndpoint(
                baseURL: url,
                tenant: "default",
                bankID: bankID,
                apiKey: config.apiKey ?? envAPIKey
            )

        default:
            throw HindsightEndpointError.unsupportedMode(mode)
        }
    }

    static func normalizeMode(_ mode: String) -> String {
        mode == "local" ? "local_embedded" : mode
    }

    /// The embedded daemon's port: 8888 for the literal `default` profile, else
    /// the configured embedded profile's port from `metadata.json`.
    static func embeddedPort(config: HindsightConfig, metadata: HindsightProfileMetadata?) throws -> Int {
        let profileName = config.profile ?? "hermes"
        if profileName == "default" { return embeddedDefaultPort }
        if let resolved = metadata?.port(forProfile: profileName) { return resolved }
        throw HindsightEndpointError.embeddedProfilePortUnknown(profile: profileName)
    }

    // MARK: - bank_id template (mirrors Hermes `_resolve_bank_id_template`)

    /// Resolve a `bank_id_template` against the available placeholders, mirroring Hermes'
    /// sanitize → render → collapse → strip → fallback pipeline. An empty template, an
    /// unknown placeholder, or an empty result all fall back to `fallback`.
    public static func resolveBankID(
        template: String,
        fallback: String,
        profile: String = "",
        workspace: String = "",
        platform: String = "",
        user: String = "",
        session: String = ""
    ) -> String {
        guard !template.isEmpty else { return fallback }
        let subs = [
            "profile": sanitizeBankSegment(profile),
            "workspace": sanitizeBankSegment(workspace),
            "platform": sanitizeBankSegment(platform),
            "user": sanitizeBankSegment(user),
            "session": sanitizeBankSegment(session),
        ]
        guard var rendered = renderTemplate(template, subs) else { return fallback }
        while rendered.contains("--") { rendered = rendered.replacingOccurrences(of: "--", with: "-") }
        while rendered.contains("__") { rendered = rendered.replacingOccurrences(of: "__", with: "_") }
        rendered = rendered.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return rendered.isEmpty ? fallback : rendered
    }

    /// Replace `non-[A-Za-z0-9_-]` runs with a single `-`, then strip leading/trailing `-_`.
    static func sanitizeBankSegment(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        var out = ""
        var prevDash = false
        for ch in value {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
                prevDash = false
            } else if !prevDash {
                out.append("-")
                prevDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    /// Render `{placeholder}` slots from `subs`; returns nil if an unknown placeholder
    /// or an unmatched `{` is encountered (→ caller falls back), matching Hermes' behaviour
    /// of treating a `str.format` failure as "use the fallback".
    private static func renderTemplate(_ template: String, _ subs: [String: String]) -> String? {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            let ch = template[index]
            if ch == "{" {
                guard let close = template[index...].firstIndex(of: "}") else { return nil }
                let key = String(template[template.index(after: index)..<close])
                guard let value = subs[key] else { return nil }
                result += value
                index = template.index(after: close)
            } else {
                result.append(ch)
                index = template.index(after: index)
            }
        }
        return result
    }
}

/// The outcome of resolving Hindsight from Hermes config: a logical endpoint plus,
/// for a **remote** `local_embedded` daemon, the remote loopback port a tunnel must
/// reach. When `remoteEmbeddedPort` is non-nil, `endpoint.baseURL` is the *remote*
/// loopback and a ``HindsightRemoteTransport`` must rewrite it to something dialable.
public struct HindsightResolution: Equatable, Sendable {
    public let endpoint: HindsightEndpoint
    public let remoteEmbeddedPort: Int?

    public init(endpoint: HindsightEndpoint, remoteEmbeddedPort: Int?) {
        self.endpoint = endpoint
        self.remoteEmbeddedPort = remoteEmbeddedPort
    }
}

/// Reads Hermes' Hindsight config + the embedded daemon metadata from disk (local or remote
/// SSH) and resolves a browsable ``HindsightEndpoint``. All reads go through ``HermesFileStore``.
public enum HindsightEndpointResolver {
    /// `hindsight/config.json` for the default profile, `profiles/<name>/hindsight/config.json` otherwise.
    public static func configRelativePath(profileName: String) -> String {
        if profileName == HermesProfiles.defaultProfileName {
            return "hindsight/config.json"
        }
        return "profiles/\(profileName)/hindsight/config.json"
    }

    /// The embedded-daemon profile/port map, under the login user's home (outside
    /// `$HERMES_HOME`). Home-relative so it resolves on both local and remote
    /// (SFTP/`cat` can't expand `~`).
    static let metadataTail = ".hindsight/profiles/metadata.json"
    static let legacyConfigTail = ".hindsight/config.json"

    public static func resolve(
        profile: ServerProfile,
        profileName: String,
        transfer: RemoteSnapshotTransfer?,
        envAPIKey: String? = nil
    ) async throws -> HindsightResolution {
        let configString: String
        do {
            configString = try await HermesFileStore.read(
                profile: profile,
                location: .profileRelative(tail: configRelativePath(profileName: profileName)),
                transfer: transfer
            )
        } catch HermesFileStoreError.notFound {
            // Legacy shared path used by older Hindsight installs (login-home-relative).
            configString = try await HermesFileStore.read(
                profile: profile,
                location: .homeRelative(tail: legacyConfigTail),
                transfer: transfer
            )
        }
        let config = try JSONDecoder().decode(HindsightConfig.self, from: Data(configString.utf8))

        // Best-effort: only local_embedded named profiles need the port map.
        var metadata: HindsightProfileMetadata?
        if let metaString = try? await HermesFileStore.read(
            profile: profile,
            location: .homeRelative(tail: metadataTail),
            transfer: transfer
        ) {
            metadata = try? JSONDecoder().decode(HindsightProfileMetadata.self, from: Data(metaString.utf8))
        }

        let placeholder = profileName == HermesProfiles.defaultProfileName ? "" : profileName
        let isRemote = profile.kind == .ssh

        // Remote + local_embedded: the daemon is on the remote loopback. Resolve
        // its port here and signal that a tunnel is needed; the caller supplies a
        // transport that makes `127.0.0.1:<remotePort>` reachable.
        if isRemote, HindsightEndpoint.normalizeMode(config.mode) == "local_embedded" {
            let port = try HindsightEndpoint.embeddedPort(config: config, metadata: metadata)
            let bankID = HindsightEndpoint.resolveBankID(
                template: config.bankIDTemplate ?? "",
                fallback: config.bankID ?? config.banksBankID ?? "hermes",
                profile: placeholder
            )
            let endpoint = HindsightEndpoint(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                tenant: "default",
                bankID: bankID,
                apiKey: nil
            )
            return HindsightResolution(endpoint: endpoint, remoteEmbeddedPort: port)
        }

        let endpoint = try HindsightEndpoint.make(
            config: config,
            metadata: metadata,
            envAPIKey: envAPIKey,
            profilePlaceholder: placeholder,
            isRemote: isRemote
        )
        return HindsightResolution(endpoint: endpoint, remoteEmbeddedPort: nil)
    }
}
