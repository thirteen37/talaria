import Foundation

/// A user-defined OpenAI-compatible endpoint — one entry in the `providers:`
/// dict of Hermes' `config.yaml`. The dict key is the stable `slug`; `name` is
/// the editable display label. The API key itself is never modeled here: it
/// lives in `~/.hermes/.env` under a derived var name, and `config.yaml` keeps
/// only a `${VAR}` reference, so this type carries `hasAPIKey` rather than the
/// secret.
public struct CustomEndpoint: Equatable, Sendable, Identifiable {
    /// The `providers.<slug>` dict key — stable across renames so the derived
    /// env-var name never moves.
    public let slug: String
    public var name: String
    public var baseURL: String
    /// Manually-listed model IDs (`models:` dict keys), merged with live
    /// discovery by Hermes. Empty when relying purely on auto-detect.
    public var models: [String]
    /// Optional `model:` default.
    public var defaultModel: String?
    /// `discover_models` — when true (the default) Hermes live-fetches the
    /// endpoint's model list.
    public var discoverModels: Bool
    /// Whether an API key is configured (derived from the config `api_key`
    /// field being non-empty). The value is read on demand via the env reveal
    /// route, not held here.
    public var hasAPIKey: Bool

    public var id: String { slug }

    public init(
        slug: String,
        name: String,
        baseURL: String,
        models: [String],
        defaultModel: String?,
        discoverModels: Bool,
        hasAPIKey: Bool
    ) {
        self.slug = slug
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.discoverModels = discoverModels
        self.hasAPIKey = hasAPIKey
    }

    // MARK: - Derived names

    /// Deterministic `.env` var name for a slug:
    /// `HERMES_CUSTOM_<SLUG_UPPER>_API_KEY`, where the slug is uppercased and
    /// every non-alphanumeric becomes `_`. Stable because the slug is stable.
    public static func apiKeyEnvVarName(forSlug slug: String) -> String {
        let upper = slug.uppercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "_"
        }
        return "HERMES_CUSTOM_\(String(upper))_API_KEY"
    }

    /// Slugifies `name` (lowercase, runs of non-alphanumerics → a single `-`,
    /// trimmed) mirroring Hermes' `custom_provider_slug`, then de-dupes against
    /// `existing` keys by appending `-2`, `-3`, … An all-symbol name yields the
    /// fallback base `endpoint`.
    public static func slug(forName name: String, existing: [String]) -> String {
        var base = ""
        var lastWasDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                base.append(ch)
                lastWasDash = false
            } else if !lastWasDash {
                base.append("-")
                lastWasDash = true
            }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "endpoint" }

        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: - Config (de)serialization

    /// Decodes the `providers` object into endpoints, sorted by name then slug
    /// for a stable display order. A missing/non-object `providers` → `[]`.
    public static func list(in config: JSONValue) -> [CustomEndpoint] {
        guard case let .object(root) = config,
              case let .object(providers) = root["providers"] else {
            return []
        }
        let endpoints = providers.map { slug, value -> CustomEndpoint in
            let fields: [String: JSONValue]
            if case let .object(object) = value { fields = object } else { fields = [:] }

            let name = string(fields["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? slug
            let baseURL = string(fields["base_url"]) ?? ""
            let defaultModel = string(fields["model"]).flatMap { $0.isEmpty ? nil : $0 }
            let discover: Bool
            if case let .bool(flag) = fields["discover_models"] { discover = flag } else { discover = true }
            let hasKey = (string(fields["api_key"]).map { !$0.isEmpty }) ?? false

            var models: [String] = []
            if case let .object(modelsObject) = fields["models"] {
                models = modelsObject.keys.sorted()
            } else if case let .array(modelsArray) = fields["models"] {
                models = modelsArray.compactMap { string($0) }
            }

            return CustomEndpoint(
                slug: slug,
                name: name,
                baseURL: baseURL,
                models: models,
                defaultModel: defaultModel,
                discoverModels: discover,
                hasAPIKey: hasKey
            )
        }
        return endpoints.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.slug < rhs.slug : lhs.name < rhs.name
        }
    }

    /// How `upsert` should treat the endpoint's `api_key` field.
    public enum APIKeyWrite: Equatable, Sendable {
        /// A fresh secret was stored in `.env` under the derived var — write the
        /// `${HERMES_CUSTOM_<SLUG>_API_KEY}` reference.
        case set
        /// Keep whatever `api_key` the existing entry already has, untouched —
        /// including a user's own `${VAR}` or a literal. Used when editing a
        /// keyed endpoint without entering a new key, so auth isn't broken by
        /// repointing at an unset derived var.
        case keep
        /// Remove any `api_key` (the endpoint has no key).
        case remove
    }

    /// Writes `providers.<slug>` from `endpoint`, preserving every other config
    /// key and sibling provider. The edited entry is *merged* into its existing
    /// value rather than rebuilt, so per-provider keys the app doesn't model
    /// (and per-model override objects for models the user keeps) survive an
    /// edit. The `apiKey` action governs the `api_key` field — see
    /// ``APIKeyWrite``. A plaintext secret is never written here.
    public static func upsert(_ endpoint: CustomEndpoint, apiKey action: APIKeyWrite, in config: JSONValue) -> JSONValue {
        var root: [String: JSONValue]
        if case let .object(object) = config { root = object } else { root = [:] }
        var providers: [String: JSONValue]
        if case let .object(object) = root["providers"] { providers = object } else { providers = [:] }

        // Start from the existing entry so unmodeled keys aren't dropped on edit.
        var entry: [String: JSONValue]
        if case let .object(existing) = providers[endpoint.slug] { entry = existing } else { entry = [:] }
        var existingModels: [String: JSONValue] = [:]
        if case let .object(models) = entry["models"] { existingModels = models }

        entry["name"] = .string(endpoint.name)
        entry["base_url"] = .string(endpoint.baseURL)
        switch action {
        case .set:
            entry["api_key"] = .string("${\(apiKeyEnvVarName(forSlug: endpoint.slug))}")
        case .keep:
            break // leave the merged-in api_key as-is
        case .remove:
            entry.removeValue(forKey: "api_key")
        }
        if let defaultModel = endpoint.defaultModel, !defaultModel.isEmpty {
            entry["model"] = .string(defaultModel)
        } else {
            entry.removeValue(forKey: "model")
        }
        if endpoint.models.isEmpty {
            entry.removeValue(forKey: "models")
        } else {
            // Keep each kept model's existing override object; new models start
            // empty. Models the user removed simply aren't re-added.
            entry["models"] = .object(Dictionary(uniqueKeysWithValues: endpoint.models.map { id in
                (id, existingModels[id] ?? .object([:]))
            }))
        }
        entry["discover_models"] = .bool(endpoint.discoverModels)

        providers[endpoint.slug] = .object(entry)
        root["providers"] = .object(providers)
        return .object(root)
    }

    /// Removes `providers.<slug>`, leaving every other key intact. A no-op when
    /// the slug is absent.
    public static func remove(slug: String, from config: JSONValue) -> JSONValue {
        guard case var .object(root) = config,
              case var .object(providers) = root["providers"] else {
            return config
        }
        providers.removeValue(forKey: slug)
        root["providers"] = .object(providers)
        return .object(root)
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }
}
