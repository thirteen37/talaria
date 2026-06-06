import Foundation
import HermesKit
import Testing
@testable import Talaria

@MainActor
@Suite
struct ModelsHarnessEndpointTests {
    /// A `providers.<slug>` endpoint, the shape the reveal tests exercise.
    private func dictEndpoint(slug: String) -> CustomEndpoint {
        CustomEndpoint(
            slug: slug, name: slug, baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .providersDict(slug: slug)
        )
    }

    @Test
    func revealReturnsValueFromEnvRevealRoute() async throws {
        let http = StatusStubHTTP(responses: [
            .init(
                path: "/api/env/reveal",
                body: Data(#"{"key":"HERMES_CUSTOM_MY_LLM_API_KEY","value":"sk-secret"}"#.utf8)
            )
        ])
        let harness = ModelsHarness(client: makeClient(http))

        let value = try await harness.revealEndpointKey(for: dictEndpoint(slug: "my-llm"))

        #expect(value == "sk-secret")
        #expect(harness.lastError == nil)
    }

    @Test
    func revealFallsBackToExpandedConfigOn404() async throws {
        // Key stored under a non-derived name → reveal 404s → fall back to the
        // expanded api_key from config (here a real, resolved secret).
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 404, body: Data(#"{"detail":"not found"}"#.utf8)),
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"api_key":"sk-from-config"}}}
            """#.utf8)),
        ])
        let harness = ModelsHarness(client: makeClient(http))

        let value = try await harness.revealEndpointKey(for: dictEndpoint(slug: "my-llm"))

        #expect(value == "sk-from-config")
    }

    @Test
    func revealReturnsNilWhenConfigHoldsOnlyUnresolvedTemplate() async throws {
        // 404 + config api_key is a bare ${VAR} (referenced var unset) → nothing
        // to reveal, but this is not an error.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 404, body: Data()),
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"api_key":"${HERMES_CUSTOM_MY_LLM_API_KEY}"}}}
            """#.utf8)),
        ])
        let harness = ModelsHarness(client: makeClient(http))

        let value = try await harness.revealEndpointKey(for: dictEndpoint(slug: "my-llm"))

        #expect(value == nil)
    }

    @Test
    func revealThrowsOnTransientErrorInsteadOfLookingLikeClearedKey() async throws {
        // A 500 must surface to the caller — not be swallowed into an empty
        // field that's indistinguishable from "no key configured".
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/env/reveal", statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        ])
        let harness = ModelsHarness(client: makeClient(http))

        await #expect(throws: DashboardClientError.self) {
            _ = try await harness.revealEndpointKey(for: dictEndpoint(slug: "my-llm"))
        }
    }

    @Test
    func saveNewEndpointDeDupesSlugAgainstFreshConfigNotStaleMemory() async throws {
        // A provider added by another window/hand-edit is present in the freshly
        // fetched config but absent from the (never-refreshed) in-memory list.
        // The derived slug must de-dup against the fresh config so the existing
        // provider isn't overwritten in place.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"name":"Existing","base_url":"https://old/v1"}}}
            """#.utf8)),                                   // GET for slug + merge
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),         // PUT
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                    // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let newEndpoint = CustomEndpoint(
            slug: "",
            name: "My LLM",            // slugifies to "my-llm" → collides
            baseURL: "https://new/v1",
            models: [],
            defaultModel: nil,
            discoverModels: true,
            hasAPIKey: false
        )

        await harness.saveEndpoint(newEndpoint, newKey: nil)

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try #require((json["config"] as? [String: Any])?["providers"] as? [String: Any])
        // Existing provider survives untouched; the new one lands under -2.
        #expect((providers["my-llm"] as? [String: Any])?["name"] as? String == "Existing")
        let added = try #require(providers["my-llm-2"] as? [String: Any])
        #expect(added["name"] as? String == "My LLM")
        #expect(added["base_url"] as? String == "https://new/v1")
    }

    @Test
    func saveNewEndpointDeDupesAgainstHiddenDictKeyToAvoidOverwrite() async throws {
        // The config holds a list entry AND a content-identical providers.<slug>
        // dict entry, so list(in:) hides the dict entry as a duplicate. Adding a
        // new endpoint whose name slugifies to that hidden key must not reuse the
        // key — upsert would otherwise overwrite the dict entry, destroying its
        // api_key and unmodeled settings.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"My LLM","base_url":"https://host/v1"}],"providers":{"my-llm":{"name":"My LLM","base_url":"https://host/v1","api_key":"sk-keep","headers":{"X-Org":"acme"}}}}
            """#.utf8)),                                                   // GET (slug + merge)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let newEndpoint = CustomEndpoint(
            slug: "", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false
        )

        let ok = await harness.saveEndpoint(newEndpoint, newKey: nil)
        #expect(ok == true)

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let putData = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: putData) as? [String: Any])
        let providers = try #require((json["config"] as? [String: Any])?["providers"] as? [String: Any])
        // Existing dict entry untouched — its key and unmodeled settings survive.
        let existing = try #require(providers["my-llm"] as? [String: Any])
        #expect(existing["api_key"] as? String == "sk-keep")
        #expect(existing["headers"] as? [String: Any] != nil)
        // New endpoint landed under a distinct slug, not the hidden key.
        let added = try #require(providers["my-llm-3"] as? [String: Any])
        #expect(added["name"] as? String == "My LLM")
        #expect(added["base_url"] as? String == "https://new/v1")
    }

    @Test
    func saveNewEndpointRejectsAnExactDuplicateInsteadOfSilentlyHidingIt() async throws {
        // A new endpoint matching an existing custom_providers entry on
        // (name, base_url, model) would be written to providers.<slug> but then
        // hidden by list-wins dedup on refresh. Reject it up front with an error
        // and write nothing, rather than report a success that never shows.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"My LLM","base_url":"https://host/v1"}]}
            """#.utf8)),                                                   // GET (merge)
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let dup = CustomEndpoint(
            slug: "", name: "My LLM", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false
        )

        let ok = await harness.saveEndpoint(dup, newKey: nil)

        #expect(ok == false)
        #expect(harness.lastError != nil)
        #expect(!http.recordedRequests.contains {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
    }

    @Test
    func saveReportsFailureAndDoesNotWriteKeyWhenConfigFetchFails() async throws {
        // The pre-merge getConfig fails → save reports failure (so the form can
        // keep the sheet + typed input open) and never writes the secret.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8))
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false
        )

        let ok = await harness.saveEndpoint(endpoint, newKey: "sk-typed")

        #expect(ok == false)
        #expect(harness.lastError != nil)
        #expect(!http.recordedRequests.contains { $0.url?.path == "/api/env" })
    }

    @Test
    func saveReportsSuccessOnCompletedRoundTrip() async throws {
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"{"providers":{}}"#.utf8)),     // GET (slug + merge)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),          // PUT
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                     // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false
        )

        let ok = await harness.saveEndpoint(endpoint, newKey: nil)

        #expect(ok == true)
        #expect(harness.lastError == nil)
    }

    @Test
    func removeToleratesNon404EnvDeleteAndStillRefreshes() async throws {
        // The config removal (the meaningful action) succeeds; a transient 5xx
        // from the best-effort .env cleanup must not strand the removed provider
        // in the list — removal drives the success/refresh path regardless.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"providers":{"my-llm":{"name":"My LLM"}}}
            """#.utf8)),                                                   // GET (fresh)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT (remove)
            .init(path: "/api/env", statusCode: 500, body: Data(#"{"detail":"boom"}"#.utf8)), // DELETE
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))

        await harness.removeEndpoint(dictEndpoint(slug: "my-llm"))

        #expect(harness.lastError == nil)
        // refresh() ran (it fetches options) — proving the success path drove it.
        #expect(http.recordedRequests.contains { $0.url?.path == "/api/model/options" })
    }

    // MARK: - custom_providers list-path endpoints

    @Test
    func editListEndpointMigratesItIntoTheProvidersDict() async throws {
        // Editing an endpoint that lives in `custom_providers:` migrates it into
        // the `providers:` dict (so Hermes resolves its key and discovers the
        // full model catalog) rather than rewriting the list element in place.
        // The list element is dropped, a `providers.<slug>` entry appears,
        // sibling top-level keys (here `model_aliases`) and unmodeled per-entry
        // keys (here `api_mode`) survive, and a blank key field carries the
        // existing key forward in a dict-resolvable form.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"model_aliases":{"x":"y"},"custom_providers":[{"name":"My LLM","base_url":"https://old/v1","api_mode":"chat_completions","api_key":"sk-literal"}]}
            """#.utf8)),                                                   // GET (merge)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let edited = CustomEndpoint(
            slug: "my-llm", name: "My LLM", baseURL: "https://new/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(
                .init(index: 0, name: "My LLM", baseURL: "https://old/v1", defaultModel: nil)
            )
        )

        let ok = await harness.saveEndpoint(edited, newKey: nil)
        #expect(ok == true)

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try #require(json["config"] as? [String: Any])
        // Sibling top-level key preserved.
        #expect((config["model_aliases"] as? [String: Any])?["x"] as? String == "y")
        // The list element is gone (the list is now empty).
        let list = try #require(config["custom_providers"] as? [[String: Any]])
        #expect(list.isEmpty)
        // The entry now lives under providers.<slug> with its edited fields.
        let providers = try #require(config["providers"] as? [String: Any])
        let migrated = try #require(providers["my-llm"] as? [String: Any])
        #expect(migrated["base_url"] as? String == "https://new/v1")
        // Unmodeled per-entry key preserved; blank key field carries the literal
        // forward (the dict path resolves it).
        #expect(migrated["api_mode"] as? String == "chat_completions")
        #expect(migrated["api_key"] as? String == "sk-literal")
    }

    @Test
    func editListEndpointReportsFailureAndWritesNothingWhenEntryVanished() async throws {
        // The target list entry was removed elsewhere since the last refresh.
        // The save must fail up front (so the sheet stays open with an error) and
        // write neither the typed key nor the config — no silent loss, no orphan.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"Other","base_url":"https://other/v1"}]}
            """#.utf8)),                                                   // GET (merge) — target gone
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let edited = CustomEndpoint(
            slug: "gone", name: "Gone", baseURL: "https://edited/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false,
            source: .customProvidersList(
                .init(index: 0, name: "Gone", baseURL: "https://gone/v1", defaultModel: nil)
            )
        )

        let ok = await harness.saveEndpoint(edited, newKey: "sk-typed")

        #expect(ok == false)
        #expect(harness.lastError != nil)
        #expect(!http.recordedRequests.contains { $0.url?.path == "/api/env" })      // no key written
        #expect(!http.recordedRequests.contains {                                    // no config write
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
    }

    @Test
    func editListEndpointWithNewKeyDeletesTheOrphanedOldVarOnMigration() async throws {
        // The entry references the app-managed HERMES_CUSTOM_OLD_API_KEY. Setting
        // a new key migrates it into the dict under a freshly derived var (from
        // the name "New Name" → HERMES_CUSTOM_NEW_NAME_API_KEY) and deletes the
        // stale app-managed old one, matching the dict path's no-orphan behavior.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"New Name","base_url":"https://host/v1","key_env":"HERMES_CUSTOM_OLD_API_KEY"}]}
            """#.utf8)),                                                   // GET (merge)
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8)),     // PUT new var
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT config
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8)),     // DELETE old var
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let edited = CustomEndpoint(
            slug: "new-name", name: "New Name", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(
                .init(index: 0, name: "New Name", baseURL: "https://host/v1", defaultModel: nil)
            )
        )

        let ok = await harness.saveEndpoint(edited, newKey: "sk-new")
        #expect(ok == true)

        let envReqs = http.recordedRequests.filter { $0.url?.path == "/api/env" }
        let put = try #require(envReqs.first { $0.httpMethod == "PUT" })
        let putData = try #require(put.httpBody)
        let putBody = try #require(try JSONSerialization.jsonObject(with: putData) as? [String: Any])
        #expect(putBody["key"] as? String == "HERMES_CUSTOM_NEW_NAME_API_KEY")
        #expect(putBody["value"] as? String == "sk-new")
        let del = try #require(envReqs.first { $0.httpMethod == "DELETE" })
        let delData = try #require(del.httpBody)
        let delBody = try #require(try JSONSerialization.jsonObject(with: delData) as? [String: Any])
        #expect(delBody["key"] as? String == "HERMES_CUSTOM_OLD_API_KEY")

        // The migrated dict entry references the new derived var, not the old one.
        let put2 = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let cfgData = try #require(put2.httpBody)
        let cfg = try #require(try JSONSerialization.jsonObject(with: cfgData) as? [String: Any])
        let providers = try #require((cfg["config"] as? [String: Any])?["providers"] as? [String: Any])
        let migrated = try #require(providers["new-name"] as? [String: Any])
        #expect(migrated["api_key"] as? String == "${HERMES_CUSTOM_NEW_NAME_API_KEY}")
    }

    @Test
    func editListEndpointWithNewKeyMigratesAndWritesDerivedRefStrippingLiteral() async throws {
        // Entering a new key while editing a list endpoint stores the secret in
        // `.env` under the derived var and migrates the entry into the dict with
        // an `api_key: ${derived-var}` reference, dropping the old literal so the
        // secret never lands in config.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"My LLM","base_url":"https://host/v1","api_key":"sk-old-literal"}]}
            """#.utf8)),                                                   // GET (merge)
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8)),     // PUT env var
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT config
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let edited = CustomEndpoint(
            slug: "my-llm", name: "My LLM", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(
                .init(index: 0, name: "My LLM", baseURL: "https://host/v1", defaultModel: nil)
            )
        )

        let ok = await harness.saveEndpoint(edited, newKey: "sk-new")
        #expect(ok == true)

        // Secret written to .env under the derived var.
        let envPut = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/env"
        })
        let envData = try #require(envPut.httpBody)
        let envBody = try #require(try JSONSerialization.jsonObject(with: envData) as? [String: Any])
        #expect(envBody["key"] as? String == "HERMES_CUSTOM_MY_LLM_API_KEY")
        #expect(envBody["value"] as? String == "sk-new")

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let putData = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: putData) as? [String: Any])
        let config = try #require(json["config"] as? [String: Any])
        // Migrated out of the list into the dict.
        let list = try #require(config["custom_providers"] as? [[String: Any]])
        #expect(list.isEmpty)
        let providers = try #require(config["providers"] as? [String: Any])
        let migrated = try #require(providers["my-llm"] as? [String: Any])
        #expect(migrated["api_key"] as? String == "${HERMES_CUSTOM_MY_LLM_API_KEY}")
        #expect(migrated["key_env"] == nil)
    }

    @Test
    func removeListEndpointDropsListElementOnly() async throws {
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"Gone","base_url":"https://gone/v1"},{"name":"Keep","base_url":"https://keep/v1"}]}
            """#.utf8)),                                                   // GET (fresh)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT (remove)
            .init(path: "/api/env", statusCode: 404, body: Data()),        // DELETE (no derived var)
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "gone", name: "Gone", baseURL: "https://gone/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: false,
            source: .customProvidersList(
                .init(index: 0, name: "Gone", baseURL: "https://gone/v1", defaultModel: nil)
            )
        )

        await harness.removeEndpoint(endpoint)

        #expect(harness.lastError == nil)
        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let putData = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: putData) as? [String: Any])
        let list = try #require((json["config"] as? [String: Any])?["custom_providers"] as? [[String: Any]])
        #expect(list.count == 1)
        #expect(list[0]["name"] as? String == "Keep")
    }

    @Test
    func revealListEndpointReadsStoredKeyEnvNotTheDriftedSlug() async throws {
        // The list entry was renamed after an app-managed key was set, so its
        // synthesized slug ("renamed") no longer matches the stored
        // `key_env: HERMES_CUSTOM_MY_LLM_API_KEY`. Reveal must read the stored
        // var, not the slug-derived one (which would 404 → "no key").
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"Renamed","base_url":"https://host/v1","key_env":"HERMES_CUSTOM_MY_LLM_API_KEY"}]}
            """#.utf8)),
            .init(
                path: "/api/env/reveal",
                body: Data(#"{"key":"HERMES_CUSTOM_MY_LLM_API_KEY","value":"sk-secret"}"#.utf8)
            ),
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "renamed", name: "Renamed", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(
                .init(index: 0, name: "Renamed", baseURL: "https://host/v1", defaultModel: nil)
            )
        )

        let value = try await harness.revealEndpointKey(for: endpoint)
        #expect(value == "sk-secret")

        let reveal = try #require(http.recordedRequests.first { $0.url?.path == "/api/env/reveal" })
        let revealData = try #require(reveal.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: revealData) as? [String: Any])
        // Revealed the entry's stored var, not HERMES_CUSTOM_RENAMED_API_KEY.
        #expect(body["key"] as? String == "HERMES_CUSTOM_MY_LLM_API_KEY")
    }

    @Test
    func removeListEndpointDeletesStoredKeyEnvNotTheDriftedSlug() async throws {
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"Renamed","base_url":"https://host/v1","key_env":"HERMES_CUSTOM_MY_LLM_API_KEY"}]}
            """#.utf8)),                                                   // GET (fresh)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT (remove)
            .init(path: "/api/env", body: Data(#"{"ok":true}"#.utf8)),     // DELETE env
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "renamed", name: "Renamed", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(
                .init(index: 0, name: "Renamed", baseURL: "https://host/v1", defaultModel: nil)
            )
        )

        await harness.removeEndpoint(endpoint)

        #expect(harness.lastError == nil)
        let del = try #require(http.recordedRequests.first {
            $0.httpMethod == "DELETE" && $0.url?.path == "/api/env"
        })
        let delData = try #require(del.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: delData) as? [String: Any])
        #expect(body["key"] as? String == "HERMES_CUSTOM_MY_LLM_API_KEY")
    }

    @Test
    func removeListEndpointLeavesUserOwnedKeyVarUntouched() async throws {
        // The entry references the user's own var (not an app-managed
        // HERMES_CUSTOM_*), so removal must NOT delete it — it could be shared.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/config", body: Data(#"""
            {"custom_providers":[{"name":"Mine","base_url":"https://host/v1","api_key_env":"MY_SHARED_KEY"}]}
            """#.utf8)),                                                   // GET (fresh)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),  // PUT (remove)
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        let endpoint = CustomEndpoint(
            slug: "mine", name: "Mine", baseURL: "https://host/v1",
            models: [], defaultModel: nil, discoverModels: true, hasAPIKey: true,
            source: .customProvidersList(
                .init(index: 0, name: "Mine", baseURL: "https://host/v1", defaultModel: nil)
            )
        )

        await harness.removeEndpoint(endpoint)

        #expect(harness.lastError == nil)
        #expect(!http.recordedRequests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/env" })
    }

    // MARK: - Auxiliary base_url cleanup

    @Test
    func changingAuxiliaryProviderClearsStaleBaseURL() async throws {
        // The set route writes only provider/model, so a base_url left from an
        // earlier `hermes model` run would linger and silently override the new
        // provider's endpoint. The harness follows the set with a config edit
        // that drops it — touching only the changed slot.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/model/set", body: Data(#"{"ok":true}"#.utf8)),               // POST set
            .init(path: "/api/config", body: Data(#"""
            {"auxiliary":{"title_generation":{"provider":"binky-litellm","model":"fast","base_url":"http://grendahl.local:49437/v1"},"vision":{"provider":"x","model":"y","base_url":"http://keep/v1"}}}
            """#.utf8)),                                                                    // GET (clear)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),                   // PUT (clear)
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        harness.beginPick(.auxiliary(task: "title_generation"))

        await harness.selectModel(provider: "binky-litellm", model: "fast")

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let aux = try #require((json["config"] as? [String: Any])?["auxiliary"] as? [String: Any])
        let title = try #require(aux["title_generation"] as? [String: Any])
        #expect(title["base_url"] == nil)                          // cleared
        #expect(title["provider"] as? String == "binky-litellm")   // provider/model survive
        #expect(title["model"] as? String == "fast")
        // Sibling slot's base_url untouched — only the changed slot is cleared.
        let vision = try #require(aux["vision"] as? [String: Any])
        #expect(vision["base_url"] as? String == "http://keep/v1")
        #expect(harness.lastError == nil)
    }

    @Test
    func changingAuxiliaryProviderSkipsConfigWriteWhenNoStaleBaseURL() async throws {
        // Nothing to clear ⇒ no needless PUT (the clear transform returns an
        // equal value and the harness compares before writing).
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/model/set", body: Data(#"{"ok":true}"#.utf8)),
            .init(path: "/api/config", body: Data(#"""
            {"auxiliary":{"title_generation":{"provider":"binky-litellm","model":"fast"}}}
            """#.utf8)),                                                                    // GET (clear) — no base_url
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))
        harness.beginPick(.auxiliary(task: "title_generation"))

        await harness.selectModel(provider: "binky-litellm", model: "fast")

        #expect(harness.lastError == nil)
        #expect(!http.recordedRequests.contains {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
    }

    @Test
    func changingMainModelDoesNotEditConfig() async throws {
        // The main model lives elsewhere; its change must never trigger an
        // auxiliary base_url config edit.
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/model/set", body: Data(#"{"ok":true}"#.utf8)),
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                             // refresh GET only
        ])
        let harness = ModelsHarness(client: makeClient(http))
        harness.beginPick(.main)

        await harness.selectModel(provider: "openrouter", model: "anthropic/claude-opus-4.7")

        #expect(harness.lastError == nil)
        #expect(!http.recordedRequests.contains {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
    }

    @Test
    func resettingAllAuxiliaryClearsEveryStaleBaseURL() async throws {
        let http = StatusStubHTTP(responses: [
            .init(path: "/api/model/set", body: Data(#"{"ok":true}"#.utf8)),               // POST __reset__
            .init(path: "/api/config", body: Data(#"""
            {"auxiliary":{"title_generation":{"provider":"auto","model":"","base_url":"http://grendahl.local:49437/v1"},"vision":{"provider":"auto","model":"","base_url":"http://x/v1"}},"other":{"k":"v"}}
            """#.utf8)),                                                                    // GET (clear)
            .init(path: "/api/config", body: Data(#"{"ok":true}"#.utf8)),                   // PUT (clear)
            .init(path: "/api/model/options", body: Data(#"{"providers":[]}"#.utf8)),
            .init(path: "/api/model/auxiliary", body: Data(#"{"tasks":[],"main":{}}"#.utf8)),
            .init(path: "/api/config", body: Data("{}".utf8)),                             // refresh GET
        ])
        let harness = ModelsHarness(client: makeClient(http))

        await harness.resetAllAuxiliary()

        let put = try #require(http.recordedRequests.first {
            $0.httpMethod == "PUT" && $0.url?.path == "/api/config"
        })
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try #require(json["config"] as? [String: Any])
        let aux = try #require(config["auxiliary"] as? [String: Any])
        #expect((aux["title_generation"] as? [String: Any])?["base_url"] == nil)
        #expect((aux["vision"] as? [String: Any])?["base_url"] == nil)
        // Unrelated top-level key preserved.
        #expect((config["other"] as? [String: Any])?["k"] as? String == "v")
        #expect(harness.lastError == nil)
    }

    private func makeClient(_ http: StatusStubHTTP) -> DashboardClient {
        DashboardClient(
            baseURL: URL(string: "http://127.0.0.1:9119")!,
            token: { "tok" },
            http: http
        )
    }
}

/// Stub that returns arbitrary status codes and serves responses by **matching
/// path** (in queue order among same-path entries), so `refresh()`'s concurrent
/// GETs resolve deterministically. Records requests for body assertions.
private final class StatusStubHTTP: DashboardHTTP, @unchecked Sendable {
    struct Response {
        let path: String
        var statusCode: Int = 200
        var body: Data
    }

    private let queue = DispatchQueue(label: "StatusStubHTTP")
    private var responses: [Response]
    private var _recordedRequests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    var recordedRequests: [URLRequest] { queue.sync { _recordedRequests } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let match: Response? = queue.sync {
            _recordedRequests.append(request)
            guard let index = responses.firstIndex(where: { $0.path == request.url?.path }) else {
                return nil
            }
            return responses.remove(at: index)
        }
        guard let url = request.url, let match else {
            throw URLError(.unsupportedURL)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: match.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (match.body, response)
    }
}
