import Foundation

/// A user-defined OpenAI-compatible endpoint. Hermes stores these in **two**
/// on-disk shapes and reads both (see `get_compatible_custom_providers`): a
/// `custom_providers:` YAML *list* (what `hermes model` writes) and a
/// `providers:` *dict* keyed by slug (the v12+ schema). `name` is the editable
/// display label. The API key itself is never modeled here: the dict path keeps
/// it in `~/.hermes/.env` under a derived var with a `${VAR}` reference in
/// config, so this type carries `hasAPIKey` rather than the secret.
public struct CustomEndpoint: Equatable, Sendable, Identifiable {
    /// Where this endpoint lives on disk, so an edit/remove targets the right
    /// place instead of always creating a `providers.<slug>` entry.
    public enum Source: Equatable, Sendable {
        /// `providers.<slug>` — the dict key is a stable on-disk identity.
        case providersDict(slug: String)
        /// `custom_providers[…]` — a list element. Unlike a dict key, a list
        /// position is *not* stable: a concurrent reorder/insert/delete (another
        /// window on the shared dashboard, a hand edit) shifts it. So the write
        /// path re-resolves the element by its original content (``anchor``)
        /// against the freshly-fetched config, using the index only to
        /// disambiguate identical entries.
        case customProvidersList(ListAnchor)
    }

    /// The original identity of a `custom_providers` list element, captured when
    /// the config was read, used to re-find it at write time. `index` is the
    /// position then; `name`/`baseURL`/`defaultModel` are the normalized content
    /// (Hermes' dedup key) preferred over the position when they disagree.
    public struct ListAnchor: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var baseURL: String
        public var defaultModel: String?

        public init(index: Int, name: String, baseURL: String, defaultModel: String?) {
            self.index = index
            self.name = name
            self.baseURL = baseURL
            self.defaultModel = defaultModel
        }
    }

    /// Stable UI identity and the basis for the derived env-var name. For a
    /// `providersDict` entry this is the dict key; for a `customProvidersList`
    /// entry it's a slug synthesized from the name for display only (the on-disk
    /// identity is the list index in ``source``).
    public let slug: String
    public var name: String
    public var baseURL: String
    /// Manually-listed model IDs (`models:` dict keys), merged with live
    /// discovery by Hermes. Empty when relying purely on auto-detect.
    public var models: [String]
    /// Optional `model:`/`default_model:` default.
    public var defaultModel: String?
    /// `discover_models` — when true (the default) Hermes live-fetches the
    /// endpoint's model list.
    public var discoverModels: Bool
    /// Whether an API key is configured — derived from a non-empty `api_key`
    /// **or** a `key_env`/`api_key_env` reference. The value itself is read on
    /// demand via the env reveal route, not held here.
    public var hasAPIKey: Bool
    /// Where the endpoint lives on disk — drives where edits/removes are written.
    public var source: Source

    public var id: String { slug }

    public init(
        slug: String,
        name: String,
        baseURL: String,
        models: [String],
        defaultModel: String?,
        discoverModels: Bool,
        hasAPIKey: Bool,
        source: Source = .providersDict(slug: "")
    ) {
        self.slug = slug
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.discoverModels = discoverModels
        self.hasAPIKey = hasAPIKey
        self.source = source
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

    /// Decodes endpoints from **both** on-disk shapes, mirroring Hermes'
    /// `get_compatible_custom_providers()`: the `custom_providers:` list (what
    /// `hermes model` writes) and the `providers:` dict. List entries win on a
    /// `(name, base_url, model)` collision, matching Hermes' dedup. The result
    /// is sorted by name then slug for a stable display order.
    public static func list(in config: JSONValue) -> [CustomEndpoint] {
        guard case let .object(root) = config else { return [] }

        var endpoints: [CustomEndpoint] = []
        var seen: Set<String> = []      // (name, base_url, model) dedup keys
        var usedSlugs: [String] = []    // display slugs taken so far

        func dedupKey(_ fields: ParsedFields) -> String {
            "\(fields.name)\u{1}\(fields.baseURL)\u{1}\(fields.defaultModel ?? "")"
        }

        // Reserve the `providers` dict keys up front: they're fixed on-disk
        // identities, so a synthesized list slug must avoid them or two distinct
        // endpoints would share an `id` (colliding in the SwiftUI ForEach and the
        // slug-keyed busy set).
        if case let .object(providers) = root["providers"] {
            usedSlugs.append(contentsOf: providers.keys)
        }

        // 1. custom_providers list — canonical CLI format; wins on collision.
        if case let .array(list) = root["custom_providers"] {
            for (index, value) in list.enumerated() {
                guard case let .object(object) = value else { continue }
                let parsed = parseFields(object, fallbackName: nil)
                let key = dedupKey(parsed)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let slug = slug(forName: parsed.name, existing: usedSlugs)
                usedSlugs.append(slug)
                let anchor = ListAnchor(
                    index: index,
                    name: parsed.name,
                    baseURL: parsed.baseURL,
                    defaultModel: parsed.defaultModel
                )
                endpoints.append(parsed.endpoint(slug: slug, source: .customProvidersList(anchor)))
            }
        }

        // 2. providers dict — v12+ schema; skipped where it duplicates a list entry.
        if case let .object(providers) = root["providers"] {
            for (slug, value) in providers {
                let object: [String: JSONValue]
                if case let .object(fields) = value { object = fields } else { object = [:] }
                let parsed = parseFields(object, fallbackName: slug)
                let key = dedupKey(parsed)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                usedSlugs.append(slug)
                endpoints.append(parsed.endpoint(slug: slug, source: .providersDict(slug: slug)))
            }
        }

        return endpoints.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.slug < rhs.slug : lhs.name < rhs.name
        }
    }

    /// Normalized fields shared by both on-disk shapes. Mirrors Hermes'
    /// `_normalize_custom_provider_entry`: URL from `base_url`/`url`/`api`,
    /// default model from `model`/`default_model`, a key from `api_key` **or**
    /// `key_env`/`api_key_env`, and `models` from either a dict or a list.
    private struct ParsedFields {
        var name: String
        var baseURL: String
        var defaultModel: String?
        var discoverModels: Bool
        var models: [String]
        var hasAPIKey: Bool

        func endpoint(slug: String, source: Source) -> CustomEndpoint {
            CustomEndpoint(
                slug: slug,
                name: name,
                baseURL: baseURL,
                models: models,
                defaultModel: defaultModel,
                discoverModels: discoverModels,
                hasAPIKey: hasAPIKey,
                source: source
            )
        }
    }

    private static func parseFields(_ fields: [String: JSONValue], fallbackName: String?) -> ParsedFields {
        let name = string(fields["name"]).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName ?? "endpoint"
        let baseURL = string(fields["base_url"]) ?? string(fields["url"]) ?? string(fields["api"]) ?? ""
        let defaultModel = (string(fields["model"]) ?? string(fields["default_model"]))
            .flatMap { $0.isEmpty ? nil : $0 }
        let discover: Bool
        if case let .bool(flag) = fields["discover_models"] { discover = flag } else { discover = true }

        var models: [String] = []
        if case let .object(modelsObject) = fields["models"] {
            models = modelsObject.keys.sorted()
        } else if case let .array(modelsArray) = fields["models"] {
            models = modelsArray.compactMap { string($0) }
        }

        let hasLiteralKey = (string(fields["api_key"]).map { !$0.isEmpty }) ?? false
        let hasKeyEnv = ((string(fields["key_env"]) ?? string(fields["api_key_env"]))
            .map { !$0.isEmpty }) ?? false

        return ParsedFields(
            name: name,
            baseURL: baseURL,
            defaultModel: defaultModel,
            discoverModels: discover,
            models: models,
            hasAPIKey: hasLiteralKey || hasKeyEnv
        )
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

    /// Rewrites the `custom_providers` element identified by `anchor` in place
    /// from `endpoint`. **Note:** the app's save path no longer edits list
    /// entries in place — it migrates them into the `providers:` dict via
    /// ``migrateListEntryToDict(_:apiKey:from:in:)`` so Hermes resolves their key
    /// and discovers the full model catalog. This in-place rewriter is kept as a
    /// tested utility. It preserves keys the app doesn't model (`api_mode`,
    /// `rate_limit_delay`, `extra_body`, per-model overrides for kept models, …)
    /// and **not** creating a `providers.<slug>` entry. The element is re-found
    /// by its original content against the freshly-fetched config (the position
    /// is only a tiebreaker), so a concurrent reorder can't make the write land
    /// on an unrelated provider. When the original element is gone (deleted
    /// elsewhere since the read) the write is a no-op rather than overwriting a
    /// stranger or appending a duplicate. The URL is canonicalized onto
    /// `base_url` (the `url`/`api` aliases are dropped) and the default model
    /// onto `model`. The `apiKey` action governs the key — see ``APIKeyWrite``;
    /// for the list path a `.set` writes a `key_env:` reference (stripping any
    /// literal `api_key`), since `hermes model` stores the secret literally.
    public static func upsertListEntry(
        _ endpoint: CustomEndpoint,
        apiKey action: APIKeyWrite,
        anchor: ListAnchor,
        in config: JSONValue
    ) -> JSONValue {
        var root: [String: JSONValue]
        if case let .object(object) = config { root = object } else { root = [:] }
        var list: [JSONValue]
        if case let .array(array) = root["custom_providers"] { list = array } else { list = [] }

        // Re-resolve by content; if the original element is gone, leave the
        // config untouched rather than corrupting an unrelated entry.
        guard let index = listIndex(matching: anchor, in: list),
              case let .object(found) = list[index] else {
            return .object(root)
        }
        var entry = found
        var existingModels: [String: JSONValue] = [:]
        if case let .object(models) = entry["models"] { existingModels = models }

        entry["name"] = .string(endpoint.name)
        // Canonicalize the URL onto base_url so there's a single source of truth.
        entry["base_url"] = .string(endpoint.baseURL)
        entry.removeValue(forKey: "url")
        entry.removeValue(forKey: "api")

        switch action {
        case .set:
            entry["key_env"] = .string(apiKeyEnvVarName(forSlug: endpoint.slug))
            // Strip both the literal and the `api_key_env` alias so the freshly
            // written `key_env` is the only key reference — a stale alias could
            // otherwise shadow it if Hermes resolves it first.
            entry.removeValue(forKey: "api_key")
            entry.removeValue(forKey: "api_key_env")
        case .keep:
            break // leave the existing api_key/key_env untouched
        case .remove:
            entry.removeValue(forKey: "api_key")
            entry.removeValue(forKey: "key_env")
            entry.removeValue(forKey: "api_key_env")
        }

        if let defaultModel = endpoint.defaultModel, !defaultModel.isEmpty {
            entry["model"] = .string(defaultModel)
        } else {
            entry.removeValue(forKey: "model")
        }
        entry.removeValue(forKey: "default_model")

        if endpoint.models.isEmpty {
            entry.removeValue(forKey: "models")
        } else {
            entry["models"] = .object(Dictionary(uniqueKeysWithValues: endpoint.models.map { id in
                (id, existingModels[id] ?? .object([:]))
            }))
        }
        entry["discover_models"] = .bool(endpoint.discoverModels)

        list[index] = .object(entry)
        root["custom_providers"] = .array(list)
        return .object(root)
    }

    /// Migrates the `custom_providers` element identified by `anchor` into a
    /// `providers.<endpoint.slug>` dict entry in one atomic transform: the list
    /// element is removed and the dict entry written in the same returned config,
    /// so the removal and the new entry land in a single `PUT` (and `list(in:)`'s
    /// list-wins dedup can't hide the migrated result behind the entry being
    /// removed).
    ///
    /// Why migrate at all: Hermes' `custom_providers` list path reads only a
    /// literal `api_key` and ignores a `key_env:` reference — so a list entry
    /// keyed by `key_env` (the shape Talaria writes to keep secrets out of
    /// config) skips live `/models` discovery and collapses to its single
    /// configured model. The `providers:` dict path resolves both `api_key: ${VAR}`
    /// and `key_env:`, so moving the entry there restores full discovery. The
    /// stored secret in `.env` does **not** move; only the config *shape* changes.
    ///
    /// The new dict entry is seeded from the found list element so unmodeled
    /// per-entry keys (`api_mode`, `extra_body`, per-model overrides, …) survive,
    /// then the modeled fields and the API key are written by reusing ``upsert``.
    /// The `apiKey` action governs the key — see ``APIKeyWrite``:
    /// - `.set` → `upsert` writes the derived `${HERMES_CUSTOM_<slug>_API_KEY}`
    ///   reference (the secret is stored under that var by the caller).
    /// - `.keep` → the list element's current key reference is carried forward as
    ///   an `api_key` value the dict path can resolve: `key_env`/`api_key_env: V`
    ///   becomes `api_key: ${V}`; a literal (or existing `${VAR}`) `api_key` is
    ///   carried verbatim. The secret does not move.
    /// - `.remove` → no key is written.
    ///
    /// The element is re-found by content against the freshly-fetched config (the
    /// anchored position is only a tiebreaker). When the original element is gone
    /// (deleted elsewhere since the read) the config is returned untouched rather
    /// than materializing a dict entry from nothing.
    public static func migrateListEntryToDict(
        _ endpoint: CustomEndpoint,
        apiKey action: APIKeyWrite,
        from anchor: ListAnchor,
        in config: JSONValue
    ) -> JSONValue {
        // Read the element before removing it; if it's gone, leave config alone.
        guard let found = listEntry(for: anchor, in: config) else { return config }
        guard case var .object(root) = removeListEntry(anchor: anchor, from: config) else {
            return config
        }
        var providers: [String: JSONValue]
        if case let .object(object) = root["providers"] { providers = object } else { providers = [:] }

        // Seed the dict entry from the list element so unmodeled keys survive,
        // dropping the URL/model aliases (`upsert` canonicalizes onto
        // `base_url`/`model` but doesn't strip the aliases) and the list-form key
        // references (`key_env`/`api_key_env`, which the dict path doesn't use).
        var seed = found
        seed.removeValue(forKey: "url")
        seed.removeValue(forKey: "api")
        seed.removeValue(forKey: "default_model")
        seed.removeValue(forKey: "key_env")
        seed.removeValue(forKey: "api_key_env")
        switch action {
        case .keep:
            // Carry the existing key forward in a form the dict path resolves, so
            // `upsert(.keep)` (which leaves api_key untouched) preserves it.
            if let carried = carriedKeyReference(found) {
                seed["api_key"] = .string(carried)
            } else {
                seed.removeValue(forKey: "api_key")
            }
        case .set, .remove:
            // `upsert` owns api_key here (writes the derived ref / removes it).
            seed.removeValue(forKey: "api_key")
        }

        providers[endpoint.slug] = .object(seed)
        root["providers"] = .object(providers)
        return upsert(endpoint, apiKey: action, in: .object(root))
    }

    /// The key reference a `custom_providers` element carries, normalized to a
    /// value the `providers:` dict path resolves: a `key_env`/`api_key_env: V`
    /// becomes `${V}`; a literal or `${VAR}` `api_key` is returned verbatim. Nil
    /// when the element has no key. `key_env` wins over `api_key_env` wins over a
    /// literal `api_key`, matching how the entry's key is otherwise read.
    private static func carriedKeyReference(_ entry: [String: JSONValue]) -> String? {
        if case let .string(value) = entry["key_env"], !value.isEmpty { return "${\(value)}" }
        if case let .string(value) = entry["api_key_env"], !value.isEmpty { return "${\(value)}" }
        if case let .string(value) = entry["api_key"], !value.isEmpty { return value }
        return nil
    }

    /// Removes the `custom_providers` element identified by `anchor`, re-resolved
    /// by content against the fresh config (position is only a tiebreaker), so a
    /// concurrent reorder can't delete the wrong provider. A no-op when the
    /// original element is gone.
    public static func removeListEntry(anchor: ListAnchor, from config: JSONValue) -> JSONValue {
        guard case var .object(root) = config,
              case var .array(list) = root["custom_providers"],
              let index = listIndex(matching: anchor, in: list) else {
            return config
        }
        list.remove(at: index)
        root["custom_providers"] = .array(list)
        return .object(root)
    }

    /// The raw fields of the `custom_providers` element identified by `anchor`,
    /// re-resolved by content against `config` — so a reader (e.g. the API-key
    /// reveal) finds the same element a write would, even after a reorder. Nil
    /// when the element is gone or `config`/`custom_providers` isn't the expected
    /// shape.
    public static func listEntry(for anchor: ListAnchor, in config: JSONValue) -> [String: JSONValue]? {
        guard case let .object(root) = config,
              case let .array(list) = root["custom_providers"],
              let index = listIndex(matching: anchor, in: list),
              case let .object(entry) = list[index] else {
            return nil
        }
        return entry
    }

    /// Finds the `custom_providers` element matching `anchor`'s original content
    /// (`name`/`base_url`/`model`, normalized the same way ``list(in:)`` reads
    /// them). When several elements share that content, the one at the anchored
    /// index is preferred; otherwise the first match. Nil when none match.
    private static func listIndex(matching anchor: ListAnchor, in list: [JSONValue]) -> Int? {
        var matches: [Int] = []
        for (index, value) in list.enumerated() {
            guard case let .object(object) = value else { continue }
            let parsed = parseFields(object, fallbackName: nil)
            if parsed.name == anchor.name
                && parsed.baseURL == anchor.baseURL
                && parsed.defaultModel == anchor.defaultModel {
                matches.append(index)
            }
        }
        if matches.contains(anchor.index) { return anchor.index }
        return matches.first
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case let .string(text) = value { return text }
        return nil
    }
}
