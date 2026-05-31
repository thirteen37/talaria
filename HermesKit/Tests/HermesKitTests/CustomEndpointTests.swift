import Foundation
import Testing
@testable import HermesKit

@Suite
struct CustomEndpointTests {
    // MARK: - apiKeyEnvVarName

    @Test
    func apiKeyEnvVarNameUppercasesSlugAndReplacesNonAlphanumerics() {
        #expect(CustomEndpoint.apiKeyEnvVarName(forSlug: "my-llm") == "HERMES_CUSTOM_MY_LLM_API_KEY")
        #expect(CustomEndpoint.apiKeyEnvVarName(forSlug: "qwen.coder") == "HERMES_CUSTOM_QWEN_CODER_API_KEY")
        #expect(CustomEndpoint.apiKeyEnvVarName(forSlug: "abc123") == "HERMES_CUSTOM_ABC123_API_KEY")
    }

    // MARK: - slug(forName:existing:)

    @Test
    func slugForNameSlugifies() {
        #expect(CustomEndpoint.slug(forName: "My LLM", existing: []) == "my-llm")
        #expect(CustomEndpoint.slug(forName: "Acme  AI!!", existing: []) == "acme-ai")
        #expect(CustomEndpoint.slug(forName: "  Trim Me  ", existing: []) == "trim-me")
    }

    @Test
    func slugForNameDeDupesAgainstExisting() {
        #expect(CustomEndpoint.slug(forName: "My LLM", existing: ["my-llm"]) == "my-llm-2")
        #expect(CustomEndpoint.slug(forName: "My LLM", existing: ["my-llm", "my-llm-2"]) == "my-llm-3")
    }

    @Test
    func slugForNameFallsBackWhenEmpty() {
        // An all-symbol name slugifies to "", which can't be a dict key.
        let slug = CustomEndpoint.slug(forName: "!!!", existing: [])
        #expect(!slug.isEmpty)
    }

    // MARK: - list(in:)

    @Test
    func listDecodesProvidersDict() {
        let config = JSONValue.object([
            "model": .string("anthropic/x"),
            "providers": .object([
                "my-llm": .object([
                    "name": .string("My LLM"),
                    "base_url": .string("https://host/v1"),
                    "api_key": .string("sk-secret"),
                    "model": .string("qwen3-coder"),
                    "models": .object(["qwen3-coder": .object([:])]),
                    "discover_models": .bool(true),
                ]),
            ]),
        ])

        let endpoints = CustomEndpoint.list(in: config)

        #expect(endpoints.count == 1)
        let ep = try! #require(endpoints.first)
        #expect(ep.slug == "my-llm")
        #expect(ep.name == "My LLM")
        #expect(ep.baseURL == "https://host/v1")
        #expect(ep.defaultModel == "qwen3-coder")
        #expect(ep.models == ["qwen3-coder"])
        #expect(ep.discoverModels == true)
        #expect(ep.hasAPIKey == true)
    }

    @Test
    func listDefaultsDiscoverModelsTrueAndDetectsMissingKey() {
        let config = JSONValue.object([
            "providers": .object([
                "bare": .object([
                    "base_url": .string("https://bare/v1"),
                ]),
            ]),
        ])

        let ep = try! #require(CustomEndpoint.list(in: config).first)
        #expect(ep.name == "bare") // falls back to slug
        #expect(ep.discoverModels == true)
        #expect(ep.hasAPIKey == false)
        #expect(ep.models.isEmpty)
        #expect(ep.defaultModel == nil)
    }

    @Test
    func listEmptyWhenNoProviders() {
        #expect(CustomEndpoint.list(in: .object(["model": .string("x")])).isEmpty)
        #expect(CustomEndpoint.list(in: .object([:])).isEmpty)
        #expect(CustomEndpoint.list(in: .string("not an object")).isEmpty)
    }

    @Test
    func listSortsByNameThenSlug() {
        let config = JSONValue.object([
            "providers": .object([
                "zeta": .object(["name": .string("Alpha")]),
                "alpha": .object(["name": .string("Beta")]),
            ]),
        ])
        let endpoints = CustomEndpoint.list(in: config)
        #expect(endpoints.map(\.slug) == ["zeta", "alpha"]) // Alpha < Beta by name
    }

    // MARK: - upsert

    @Test
    func upsertWritesEnvRefTemplateNeverPlaintext() {
        let endpoint = CustomEndpoint(
            slug: "my-llm",
            name: "My LLM",
            baseURL: "https://host/v1",
            models: ["qwen3-coder"],
            defaultModel: "qwen3-coder",
            discoverModels: true,
            hasAPIKey: true
        )
        let config = JSONValue.object([
            "model": .string("anthropic/x"),
            "providers": .object([
                "other": .object(["name": .string("Other")]),
            ]),
        ])

        let updated = CustomEndpoint.upsert(endpoint, apiKey: .set, in: config)

        guard case let .object(root) = updated,
              case let .object(providers) = root["providers"],
              case let .object(mine) = providers["my-llm"] else {
            Issue.record("expected providers.my-llm object")
            return
        }
        // Other top-level keys + sibling providers survive.
        #expect(root["model"] == .string("anthropic/x"))
        #expect(providers["other"] != nil)
        // api_key is the literal ${VAR} template — never the plaintext secret.
        #expect(mine["api_key"] == .string("${HERMES_CUSTOM_MY_LLM_API_KEY}"))
        #expect(mine["name"] == .string("My LLM"))
        #expect(mine["base_url"] == .string("https://host/v1"))
        #expect(mine["model"] == .string("qwen3-coder"))
        #expect(mine["discover_models"] == .bool(true))
        guard case let .object(models) = mine["models"] else {
            Issue.record("expected models dict")
            return
        }
        #expect(models["qwen3-coder"] != nil)
    }

    @Test
    func upsertOmitsAPIKeyWhenNotKeyed() {
        let endpoint = CustomEndpoint(
            slug: "no-key",
            name: "No Key",
            baseURL: "https://host/v1",
            models: [],
            defaultModel: nil,
            discoverModels: true,
            hasAPIKey: false
        )

        let updated = CustomEndpoint.upsert(endpoint, apiKey: .remove, in: .object([:]))

        guard case let .object(root) = updated,
              case let .object(providers) = root["providers"],
              case let .object(mine) = providers["no-key"] else {
            Issue.record("expected providers.no-key object")
            return
        }
        #expect(mine["api_key"] == nil)
        #expect(mine["models"] == nil) // no manual models → key omitted
        #expect(mine["model"] == nil)
    }

    @Test
    func upsertPreservesUnknownProviderKeysAndModelOverridesOnEdit() {
        // Editing must not clobber fields the app doesn't model: per-provider
        // keys Hermes may store (here `headers`) and per-model override objects
        // for models the user keeps. Only removed models drop out.
        let config = JSONValue.object([
            "providers": .object([
                "my-llm": .object([
                    "name": .string("Old"),
                    "base_url": .string("https://old/v1"),
                    "api_key": .string("${HERMES_CUSTOM_MY_LLM_API_KEY}"),
                    "headers": .object(["X-Org": .string("acme")]),
                    "models": .object([
                        "keep-me": .object(["max_tokens": .number(8192)]),
                        "drop-me": .object([:]),
                    ]),
                ]),
            ]),
        ])
        let endpoint = CustomEndpoint(
            slug: "my-llm",
            name: "New Name",
            baseURL: "https://new/v1",
            models: ["keep-me", "added"],
            defaultModel: nil,
            discoverModels: true,
            hasAPIKey: true
        )

        let updated = CustomEndpoint.upsert(endpoint, apiKey: .set, in: config)

        guard case let .object(root) = updated,
              case let .object(providers) = root["providers"],
              case let .object(mine) = providers["my-llm"] else {
            Issue.record("expected providers.my-llm object")
            return
        }
        #expect(mine["name"] == .string("New Name"))
        #expect(mine["base_url"] == .string("https://new/v1"))
        // Unknown per-provider key survives the edit.
        #expect(mine["headers"] == .object(["X-Org": .string("acme")]))
        guard case let .object(models) = mine["models"] else {
            Issue.record("expected models dict")
            return
        }
        // Kept model keeps its override; removed model is gone; new model is empty.
        #expect(models["keep-me"] == .object(["max_tokens": .number(8192)]))
        #expect(models["drop-me"] == nil)
        #expect(models["added"] == .object([:]))
    }

    @Test
    func upsertKeepPreservesNonDerivedApiKeyReference() {
        // Editing a keyed endpoint while leaving the key field blank must keep
        // the existing api_key verbatim — even when it points at a user's own
        // var or a literal — instead of rewriting it to the derived template
        // (which has no secret) and breaking auth.
        let config = JSONValue.object([
            "providers": .object([
                "my-llm": .object([
                    "name": .string("My LLM"),
                    "base_url": .string("https://host/v1"),
                    "api_key": .string("${MY_OWN_VAR}"),
                ]),
            ]),
        ])
        let endpoint = CustomEndpoint(
            slug: "my-llm",
            name: "Renamed",
            baseURL: "https://host/v2",
            models: [],
            defaultModel: nil,
            discoverModels: true,
            hasAPIKey: true
        )

        let updated = CustomEndpoint.upsert(endpoint, apiKey: .keep, in: config)

        guard case let .object(root) = updated,
              case let .object(providers) = root["providers"],
              case let .object(mine) = providers["my-llm"] else {
            Issue.record("expected providers.my-llm object")
            return
        }
        #expect(mine["api_key"] == .string("${MY_OWN_VAR}"))
        #expect(mine["name"] == .string("Renamed"))
        #expect(mine["base_url"] == .string("https://host/v2"))
    }

    @Test
    func upsertSetOverridesAnExistingNonDerivedReference() {
        // Entering a *new* key while editing such an endpoint stores it under
        // the derived var, so api_key flips to the derived template.
        let config = JSONValue.object([
            "providers": .object([
                "my-llm": .object([
                    "name": .string("My LLM"),
                    "base_url": .string("https://host/v1"),
                    "api_key": .string("${MY_OWN_VAR}"),
                ]),
            ]),
        ])
        let endpoint = CustomEndpoint(
            slug: "my-llm",
            name: "My LLM",
            baseURL: "https://host/v1",
            models: [],
            defaultModel: nil,
            discoverModels: true,
            hasAPIKey: true
        )

        let updated = CustomEndpoint.upsert(endpoint, apiKey: .set, in: config)

        guard case let .object(root) = updated,
              case let .object(providers) = root["providers"],
              case let .object(mine) = providers["my-llm"] else {
            Issue.record("expected providers.my-llm object")
            return
        }
        #expect(mine["api_key"] == .string("${HERMES_CUSTOM_MY_LLM_API_KEY}"))
    }

    @Test
    func upsertReplacesExistingSlugInPlace() {
        let config = JSONValue.object([
            "providers": .object([
                "my-llm": .object([
                    "name": .string("Old Name"),
                    "base_url": .string("https://old/v1"),
                ]),
            ]),
        ])
        let endpoint = CustomEndpoint(
            slug: "my-llm",
            name: "New Name",
            baseURL: "https://new/v1",
            models: [],
            defaultModel: nil,
            discoverModels: false,
            hasAPIKey: false
        )

        let updated = CustomEndpoint.upsert(endpoint, apiKey: .remove, in: config)
        let endpoints = CustomEndpoint.list(in: updated)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.name == "New Name")
        #expect(endpoints.first?.baseURL == "https://new/v1")
        #expect(endpoints.first?.discoverModels == false)
    }

    // MARK: - remove

    @Test
    func removeDeletesOnlyTheTargetSlug() {
        let config = JSONValue.object([
            "model": .string("anthropic/x"),
            "providers": .object([
                "my-llm": .object(["name": .string("My LLM")]),
                "keep": .object(["name": .string("Keep")]),
            ]),
        ])

        let updated = CustomEndpoint.remove(slug: "my-llm", from: config)

        guard case let .object(root) = updated,
              case let .object(providers) = root["providers"] else {
            Issue.record("expected providers object")
            return
        }
        #expect(root["model"] == .string("anthropic/x"))
        #expect(providers["my-llm"] == nil)
        #expect(providers["keep"] != nil)
    }

    @Test
    func removeIsNoOpWhenSlugAbsent() {
        let config = JSONValue.object([
            "providers": .object(["keep": .object([:])]),
        ])
        let updated = CustomEndpoint.remove(slug: "missing", from: config)
        #expect(CustomEndpoint.list(in: updated).map(\.slug) == ["keep"])
    }

    // MARK: - list(in:) — custom_providers list (the `hermes model` format)

    @Test
    func listDecodesCustomProvidersListEntry() {
        // The user's exact case: the only entry is a `custom_providers:` list
        // element written by `hermes model`, with a literal api_key.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object([
                    "name": .string("My LLM"),
                    "base_url": .string("https://host/v1"),
                    "api_key": .string("sk-literal"),
                    "model": .string("qwen3-coder"),
                    "models": .object(["qwen3-coder": .object(["context_length": .number(64000)])]),
                ]),
            ]),
        ])

        let ep = try! #require(CustomEndpoint.list(in: config).first)
        #expect(ep.name == "My LLM")
        #expect(ep.baseURL == "https://host/v1")
        #expect(ep.defaultModel == "qwen3-coder")
        #expect(ep.models == ["qwen3-coder"])
        #expect(ep.discoverModels == true) // defaulted
        #expect(ep.hasAPIKey == true)      // literal api_key
        #expect(ep.source == .customProvidersList(
            .init(index: 0, name: "My LLM", baseURL: "https://host/v1", defaultModel: "qwen3-coder")
        ))
    }

    @Test
    func listParsesProvidersDictV12Aliases() {
        // A v11→v12-migrated dict entry uses divergent keys: `api` (not
        // base_url), `default_model` (not model), `key_env` (not api_key).
        let config = JSONValue.object([
            "providers": .object([
                "my-llm": .object([
                    "name": .string("My LLM"),
                    "api": .string("https://migrated/v1"),
                    "default_model": .string("some-model"),
                    "key_env": .string("HERMES_CUSTOM_MY_LLM_API_KEY"),
                ]),
            ]),
        ])

        let ep = try! #require(CustomEndpoint.list(in: config).first)
        #expect(ep.baseURL == "https://migrated/v1")
        #expect(ep.defaultModel == "some-model")
        #expect(ep.hasAPIKey == true) // derived from key_env
        #expect(ep.source == .providersDict(slug: "my-llm"))
    }

    @Test
    func listDedupsAcrossListAndDictWithListWinning() {
        // The same endpoint present in both shapes (Hermes merges and dedups by
        // (name, base_url, model)) yields one CustomEndpoint, tagged to the list.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object(["name": .string("Dup"), "base_url": .string("https://dup/v1")]),
            ]),
            "providers": .object([
                "dup": .object(["name": .string("Dup"), "base_url": .string("https://dup/v1")]),
            ]),
        ])

        let endpoints = CustomEndpoint.list(in: config)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.source == .customProvidersList(
            .init(index: 0, name: "Dup", baseURL: "https://dup/v1", defaultModel: nil)
        ))
    }

    @Test
    func listSynthesizesDistinctSlugsForSameNamedListEntries() {
        // Two list entries with the same name must get distinct UI slugs so the
        // SwiftUI ForEach identity doesn't collide.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object(["name": .string("LLM"), "base_url": .string("https://a/v1")]),
                .object(["name": .string("LLM"), "base_url": .string("https://b/v1")]),
            ]),
        ])

        let slugs = CustomEndpoint.list(in: config).map(\.slug)
        #expect(Set(slugs).count == 2)
    }

    @Test
    func listGivesListEntryADistinctSlugFromACollidingDictKey() {
        // A list entry whose slugified name equals an existing `providers.<slug>`
        // key — but with a *different* base_url, so not a content duplicate —
        // must not inherit that key as its slug, or the two distinct endpoints
        // would share an Identifiable `id`.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object(["name": .string("My LLM"), "base_url": .string("https://list/v1")]),
            ]),
            "providers": .object([
                "my-llm": .object(["name": .string("My LLM"), "base_url": .string("https://dict/v1")]),
            ]),
        ])

        let endpoints = CustomEndpoint.list(in: config)
        #expect(endpoints.count == 2)
        #expect(Set(endpoints.map(\.slug)).count == 2) // no id collision
    }

    // MARK: - upsertListEntry / removeListEntry

    @Test
    func upsertListEntryRewritesInPlacePreservingUnmodeledKeysAndLiteralKey() {
        let config = JSONValue.object([
            "custom_providers": .array([
                .object([
                    "name": .string("My LLM"),
                    "base_url": .string("https://old/v1"),
                    "api_key": .string("sk-literal"),
                    "api_mode": .string("chat_completions"),
                    "rate_limit_delay": .number(2),
                    "models": .object(["keep": .object(["context_length": .number(8192)])]),
                ]),
            ]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 0, name: "My LLM", baseURL: "https://old/v1", defaultModel: nil
        )
        let endpoint = CustomEndpoint(
            slug: "my-llm", name: "Renamed", baseURL: "https://new/v1",
            models: ["keep", "added"], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(anchor)
        )

        let updated = CustomEndpoint.upsertListEntry(endpoint, apiKey: .keep, anchor: anchor, in: config)

        // No providers dict materialized.
        guard case let .object(root) = updated else { Issue.record("expected object"); return }
        #expect(root["providers"] == nil)
        guard case let .array(list) = root["custom_providers"],
              list.count == 1, case let .object(entry) = list[0] else {
            Issue.record("expected one list entry"); return
        }
        #expect(entry["name"] == .string("Renamed"))
        #expect(entry["base_url"] == .string("https://new/v1"))
        // Unmodeled keys survive.
        #expect(entry["api_mode"] == .string("chat_completions"))
        #expect(entry["rate_limit_delay"] == .number(2))
        // .keep leaves the literal untouched.
        #expect(entry["api_key"] == .string("sk-literal"))
        // Kept model keeps its override; new model is empty.
        guard case let .object(models) = entry["models"] else { Issue.record("expected models"); return }
        #expect(models["keep"] == .object(["context_length": .number(8192)]))
        #expect(models["added"] == .object([:]))
    }

    @Test
    func upsertListEntrySetWritesKeyEnvAndStripsLiteral() {
        let config = JSONValue.object([
            "custom_providers": .array([
                .object([
                    "name": .string("My LLM"),
                    "base_url": .string("https://host/v1"),
                    "api_key": .string("sk-old-literal"),
                    "api_key_env": .string("MY_OLD_VAR"),
                ]),
            ]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 0, name: "My LLM", baseURL: "https://host/v1", defaultModel: nil
        )
        let endpoint = CustomEndpoint(
            slug: "my-llm", name: "My LLM", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(anchor)
        )

        let updated = CustomEndpoint.upsertListEntry(endpoint, apiKey: .set, anchor: anchor, in: config)

        guard case let .object(root) = updated,
              case let .array(list) = root["custom_providers"],
              case let .object(entry) = list[0] else {
            Issue.record("expected list entry"); return
        }
        #expect(entry["key_env"] == .string("HERMES_CUSTOM_MY_LLM_API_KEY"))
        #expect(entry["api_key"] == nil)     // literal stripped
        #expect(entry["api_key_env"] == nil) // stale alias stripped so it can't shadow key_env
    }

    @Test
    func upsertListEntryCanonicalizesUrlAndModelAliases() {
        // An entry written with the `api`/`default_model` aliases is rewritten
        // onto the canonical `base_url`/`model` keys, dropping the aliases.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object([
                    "name": .string("My LLM"),
                    "api": .string("https://old/v1"),
                    "default_model": .string("old-model"),
                ]),
            ]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 0, name: "My LLM", baseURL: "https://old/v1", defaultModel: "old-model"
        )
        let endpoint = CustomEndpoint(
            slug: "my-llm", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: "new-model", discoverModels: true, hasAPIKey: false,
            source: .customProvidersList(anchor)
        )

        let updated = CustomEndpoint.upsertListEntry(endpoint, apiKey: .remove, anchor: anchor, in: config)

        guard case let .object(root) = updated,
              case let .array(list) = root["custom_providers"],
              case let .object(entry) = list[0] else {
            Issue.record("expected list entry"); return
        }
        #expect(entry["base_url"] == .string("https://new/v1"))
        #expect(entry["model"] == .string("new-model"))
        #expect(entry["api"] == nil)
        #expect(entry["default_model"] == nil)
    }

    @Test
    func removeListEntryDropsOnlyTheTargetElement() {
        let config = JSONValue.object([
            "custom_providers": .array([
                .object(["name": .string("Gone"), "base_url": .string("https://gone/v1")]),
                .object(["name": .string("Keep"), "base_url": .string("https://keep/v1")]),
            ]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 0, name: "Gone", baseURL: "https://gone/v1", defaultModel: nil
        )

        let updated = CustomEndpoint.removeListEntry(anchor: anchor, from: config)

        guard case let .object(root) = updated,
              case let .array(list) = root["custom_providers"] else {
            Issue.record("expected list"); return
        }
        #expect(list.count == 1)
        guard case let .object(kept) = list[0] else { Issue.record("expected object"); return }
        #expect(kept["name"] == .string("Keep"))
    }

    @Test
    func removeListEntryReResolvesByContentAfterAReorder() {
        // The element moved (another window inserted ahead of it) since the read,
        // so the anchored index is now stale. Content re-resolution must still
        // delete the right element — never the one that slid into the old slot.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object(["name": .string("Inserted"), "base_url": .string("https://new/v1")]),
                .object(["name": .string("Gone"), "base_url": .string("https://gone/v1")]),
            ]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 0, name: "Gone", baseURL: "https://gone/v1", defaultModel: nil
        )

        let updated = CustomEndpoint.removeListEntry(anchor: anchor, from: config)

        let remaining = CustomEndpoint.list(in: updated).map(\.name)
        #expect(remaining == ["Inserted"]) // the stale-index victim survives
    }

    @Test
    func upsertListEntryIsNoOpWhenOriginalElementIsGone() {
        // The original element was deleted elsewhere since the read. Rather than
        // overwrite a stranger or append a duplicate, the write leaves the list
        // untouched.
        let config = JSONValue.object([
            "custom_providers": .array([
                .object(["name": .string("Unrelated"), "base_url": .string("https://other/v1")]),
            ]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 0, name: "Gone", baseURL: "https://gone/v1", defaultModel: nil
        )
        let endpoint = CustomEndpoint(
            slug: "gone", name: "Gone", baseURL: "https://edited/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false,
            source: .customProvidersList(anchor)
        )

        let updated = CustomEndpoint.upsertListEntry(endpoint, apiKey: .remove, anchor: anchor, in: config)
        #expect(updated == config) // unrelated provider untouched, no duplicate
    }

    @Test
    func removeListEntryIsNoOpWhenContentDoesNotMatch() {
        let config = JSONValue.object([
            "custom_providers": .array([.object(["name": .string("Keep"), "base_url": .string("https://keep/v1")])]),
        ])
        let anchor = CustomEndpoint.ListAnchor(
            index: 5, name: "Missing", baseURL: "https://missing/v1", defaultModel: nil
        )
        let updated = CustomEndpoint.removeListEntry(anchor: anchor, from: config)
        #expect(updated == config)
    }
}
