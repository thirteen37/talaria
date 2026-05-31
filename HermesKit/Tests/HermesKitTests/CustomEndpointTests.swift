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
}
