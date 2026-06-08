import Foundation
import HermesKit

enum ScreenshotFixtures {
    static let version = "0.15.1"
    static let primarySessionID: SessionId = "fixture-release-review"
    static let baseURL = URL(string: "http://docs-fixture.local")!
    static let cwd = "/Users/fixture/projects/talaria"

    @MainActor
    static var primarySessionSummary: HermesSessionSummary {
        HermesSessionSummary(
            id: primarySessionID,
            title: "Release readiness review",
            updatedAt: Date(timeIntervalSince1970: 1_780_915_200),
            cwd: cwd,
            source: "tui",
            lastActive: Date(timeIntervalSince1970: 1_780_915_560),
            isActive: true,
            preview: "Audit release notes, screenshot docs, and the dashboard surfaces before tagging.",
            model: "gpt-5.2",
            messageCount: 12,
            toolCallCount: 4,
            tokenTotal: 18_420,
            costDisplay: "~$0.42"
        )
    }
}

struct ScreenshotFixtureDashboardHTTP: DashboardHTTP {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "GET"
        let url = request.url ?? ScreenshotFixtures.baseURL
        let path = url.path

        switch (method, path) {
        case ("GET", "/api/status"):
            return response(json: Self.status, url: url)
        case ("POST", "/api/auth/ws-ticket"):
            return response(json: #"{"ticket":"fixture-ticket","ttl_seconds":60}"#, url: url)
        case ("GET", "/api/sessions"):
            return response(json: Self.sessions, url: url)
        case ("GET", "/api/sessions/search"):
            return response(json: #"{"results":[]}"#, url: url)
        case ("GET", "/api/sessions/\(ScreenshotFixtures.primarySessionID)"):
            return response(json: #"{"id":"\#(ScreenshotFixtures.primarySessionID)","source":"tui"}"#, url: url)
        case ("GET", "/api/sessions/\(ScreenshotFixtures.primarySessionID)/messages"):
            return response(json: Self.sessionMessages, url: url)
        case ("GET", "/api/profiles"):
            return response(json: Self.profiles, url: url)
        case ("GET", "/api/skills"):
            return response(json: Self.skills, url: url)
        case ("GET", "/api/tools/toolsets"):
            return response(json: Self.toolsets, url: url)
        case ("GET", "/api/mcp/servers"):
            return response(json: Self.mcpServers, url: url)
        case ("GET", "/api/mcp/catalog"):
            return response(json: Self.mcpCatalog, url: url)
        case ("GET", "/api/dashboard/plugins/hub"):
            return response(json: Self.pluginsHub, url: url)
        case ("GET", "/api/cron/jobs"):
            return response(json: Self.cronJobs, url: url)
        case ("GET", "/api/model/options"):
            return response(json: Self.modelOptions, url: url)
        case ("GET", "/api/model/auxiliary"):
            return response(json: Self.modelAssignments, url: url)
        case ("GET", "/api/model/info"):
            return response(json: Self.modelInfo, url: url)
        case ("GET", "/api/actions/hermes-update/status"):
            return response(json: #"{"name":"hermes-update","running":false,"exit_code":0,"pid":null,"lines":["Hermes is up to date."]}"#, url: url)
        case ("GET", "/api/logs"):
            return response(json: Self.logs, url: url)
        case ("GET", "/api/memory"):
            return response(json: Self.memory, url: url)
        case ("GET", "/api/env"):
            return response(json: Self.env, url: url)
        case ("GET", "/api/config/schema"):
            return response(json: Self.configSchema, url: url)
        case ("GET", "/api/config"):
            return response(json: Self.config, url: url)
        case ("GET", "/api/config/defaults"):
            return response(json: Self.configDefaults, url: url)
        default:
            if method != "GET" {
                return response(json: #"{"ok":true}"#, url: url)
            }
            return response(
                json: #"{"detail":"No screenshot fixture for \#(method) \#(path)"}"#,
                statusCode: 404,
                url: url
            )
        }
    }

    private func response(json: String, statusCode: Int = 200, url: URL) -> (Data, URLResponse) {
        let data = Data(json.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private static let status = """
    {
      "version": "\(ScreenshotFixtures.version)",
      "release_date": "2026-06-01",
      "gateway_running": true,
      "gateway_pid": 4242,
      "gateway_state": "running",
      "gateway_health_url": "http://docs-fixture.local/health",
      "gateway_platforms": {
        "slack": {"state":"connected","error_code":null,"error_message":null,"updated_at":"2026-06-08T09:20:00Z"},
        "telegram": {"state":"connected","error_code":null,"error_message":null,"updated_at":"2026-06-08T09:18:00Z"}
      },
      "gateway_exit_reason": null,
      "gateway_updated_at": "2026-06-08T09:20:00Z"
    }
    """

    private static let sessions = """
    {
      "total": 4,
      "sessions": [
        {
          "id": "\(ScreenshotFixtures.primarySessionID)",
          "title": "Release readiness review",
          "started_at": 1780915200,
          "source": "tui",
          "model": "gpt-5.2",
          "message_count": 12,
          "tool_call_count": 4,
          "last_active": 1780915560,
          "is_active": true,
          "preview": "Audit release notes, screenshot docs, and dashboard surfaces before tagging.",
          "input_tokens": 12200,
          "output_tokens": 6220,
          "estimated_cost_usd": 0.42,
          "cost_status": "estimated"
        },
        {
          "id": "fixture-gateway-qa",
          "title": "Gateway messaging QA",
          "started_at": 1780908000,
          "source": "dashboard",
          "model": "claude-sonnet-4-5",
          "message_count": 8,
          "tool_call_count": 2,
          "last_active": 1780909860,
          "is_active": false,
          "preview": "Verify Slack, Telegram, and Discord delivery states with redacted credentials.",
          "input_tokens": 8100,
          "output_tokens": 2190,
          "estimated_cost_usd": 0.21,
          "cost_status": "estimated"
        },
        {
          "id": "fixture-cron-summary",
          "title": "Daily automation digest",
          "started_at": 1780837200,
          "source": "cron",
          "model": "gpt-5.2-mini",
          "message_count": 5,
          "tool_call_count": 3,
          "last_active": 1780840800,
          "is_active": false,
          "preview": "Summarize open release tasks and post the sanitized digest.",
          "input_tokens": 4500,
          "output_tokens": 1540,
          "estimated_cost_usd": 0.08,
          "cost_status": "estimated"
        },
        {
          "id": "fixture-model-tuning",
          "title": "Model routing check",
          "started_at": 1780750800,
          "source": "cli",
          "model": "gpt-5.2",
          "message_count": 6,
          "tool_call_count": 1,
          "last_active": 1780752600,
          "is_active": false,
          "preview": "Compare main and auxiliary model assignments for the release profile.",
          "input_tokens": 3900,
          "output_tokens": 980,
          "estimated_cost_usd": 0.05,
          "cost_status": "estimated"
        }
      ]
    }
    """

    private static let sessionMessages = """
    {
      "session_id": "\(ScreenshotFixtures.primarySessionID)",
      "messages": [
        {"role":"user","content":"Check the release docs against the current Talaria dashboard UI."},
        {"role":"assistant","content":"I found stale screenshots for the sidebar grouping and several manage surfaces. I am using fixture data so the refreshed images do not expose local profiles or sessions."},
        {"role":"user","content":"Make sure the screenshots show the new grouped Extensions page and the Models screen."},
        {"role":"assistant","content":"Done. The fixture profile uses docs-fixture.local, synthetic session titles, redacted environment values, and stable demo model assignments."}
      ]
    }
    """

    private static let profiles = """
    {"profiles":[
      {"name":"default","is_default":true,"model":"gpt-5.2","provider":"openai"},
      {"name":"release","is_default":false,"model":"claude-sonnet-4-5","provider":"anthropic"}
    ]}
    """

    private static let skills = """
    [
      {"name":"release-notes","description":"Draft release notes from merged changes and open issues.","category":"workflow","enabled":true},
      {"name":"code-review","description":"Review diffs for regressions, test gaps, and cleanup opportunities.","category":"engineering","enabled":true},
      {"name":"docs-audit","description":"Check docs for stale feature names, links, and screenshots.","category":"documentation","enabled":true},
      {"name":"incident-summary","description":"Prepare a concise operational summary from logs.","category":"operations","enabled":false}
    ]
    """

    private static let toolsets = """
    [
      {"name":"web","label":"Web","description":"Search and retrieve current public documentation.","enabled":true,"available":true,"configured":true,"tools":["web_search","web_fetch"]},
      {"name":"shell","label":"Shell","description":"Run local commands in the active workspace.","enabled":true,"available":true,"configured":true,"tools":["exec_command"]},
      {"name":"github","label":"GitHub","description":"Inspect pull requests, issues, and CI status.","enabled":true,"available":true,"configured":true,"tools":["fetch_pr","list_issues"]},
      {"name":"browser","label":"Browser","description":"Drive a browser for UI verification.","enabled":false,"available":true,"configured":false,"tools":["open_page","screenshot"]}
    ]
    """

    private static let mcpServers = """
    {"servers":[
      {"name":"docs","transport":"stdio","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/Users/fixture/docs"],"env":{},"enabled":true,"source":"user","tools":["read_file","search_files"]},
      {"name":"linear","url":"https://mcp.example.invalid/linear","headers":{},"enabled":false,"source":"catalog","tools":[]}
    ]}
    """

    private static let mcpCatalog = """
    {"entries":[
      {"name":"filesystem","description":"Read and search a scoped fixture directory.","install_hint":"npx -y @modelcontextprotocol/server-filesystem","env":[]},
      {"name":"browser","description":"Automate browser checks with a sandboxed profile.","install_hint":"npx -y @modelcontextprotocol/server-browser","env":[]}
    ],"diagnostics":[]}
    """

    private static let pluginsHub = """
    {
      "plugins": [
        {"name":"kanban","version":"0.4.0","description":"Track tasks and release boards in Hermes.","source":"bundled","runtime_status":"enabled","has_dashboard_manifest":true,"can_remove":false,"can_update_git":false,"auth_required":false,"auth_command":"","path":"/opt/hermes/plugins/kanban"},
        {"name":"memory-vector","version":"1.2.0","description":"Optional vector-backed memory provider.","source":"git","runtime_status":"disabled","has_dashboard_manifest":false,"can_remove":true,"can_update_git":true,"auth_required":false,"auth_command":"","path":"/opt/hermes/plugins/memory-vector"}
      ],
      "providers": {
        "memory_provider": "",
        "memory_options": [{"name":"","description":"Built-in MEMORY.md and USER.md files"},{"name":"memory-vector","description":"Vector-backed memory plugin"}],
        "context_engine": "default",
        "context_options": [{"name":"default","description":"Hermes default context engine"},{"name":"semantic","description":"Semantic context retrieval"}]
      }
    }
    """

    private static let cronJobs = """
    [
      {"id":"cron-release-digest","name":"Release digest","prompt":"Summarize open release tasks and flag blockers.","schedule":{"kind":"cron","expr":"0 9 * * 1-5","minutes":null,"display":"Weekdays at 09:00"},"enabled":true,"state":"idle","last_run_at":"2026-06-08T01:00:00Z","next_run_at":"2026-06-09T01:00:00Z","last_status":"success","last_error":null,"profile":"release"},
      {"id":"cron-docs-check","name":"Docs screenshot check","prompt":"Check docs screenshots for stale UI labels.","schedule":{"kind":"interval","expr":null,"minutes":240,"display":"Every 4 hours"},"enabled":true,"state":"running","last_run_at":"2026-06-08T05:00:00Z","next_run_at":"2026-06-08T09:00:00Z","last_status":"success","last_error":null,"profile":"default"},
      {"id":"cron-dependency-audit","name":"Dependency audit","prompt":"Review dependency warnings and summarize changes.","schedule":{"kind":"cron","expr":"30 16 * * 5","minutes":null,"display":"Fridays at 16:30"},"enabled":false,"state":"paused","last_run_at":"2026-06-05T08:30:00Z","next_run_at":null,"last_status":"paused","last_error":null,"profile":"default"}
    ]
    """

    private static let modelOptions = """
    {
      "provider": "openai",
      "model": "gpt-5.2",
      "providers": [
        {"slug":"openai","name":"OpenAI","is_current":true,"is_user_defined":false,"models":["gpt-5.2","gpt-5.2-mini","gpt-5.1-codex"],"total_models":3,"source":"built-in"},
        {"slug":"anthropic","name":"Anthropic","is_current":false,"is_user_defined":false,"models":["claude-sonnet-4-5","claude-haiku-4-5"],"total_models":2,"source":"built-in"},
        {"slug":"local","name":"Local OpenAI-compatible","is_current":false,"is_user_defined":true,"models":["qwen3-coder","llama-4-scout"],"total_models":2,"source":"user"}
      ]
    }
    """

    private static let modelAssignments = """
    {
      "main": {"provider":"openai","model":"gpt-5.2"},
      "tasks": [
        {"task":"coding","provider":"openai","model":"gpt-5.2","base_url":null},
        {"task":"reasoning","provider":"anthropic","model":"claude-sonnet-4-5","base_url":null},
        {"task":"vision","provider":"auto","model":"","base_url":null},
        {"task":"small","provider":"openai","model":"gpt-5.2-mini","base_url":null}
      ]
    }
    """

    private static let modelInfo = """
    {"provider":"openai","model":"gpt-5.2","auto_context_length":200000,"config_context_length":0,"effective_context_length":200000,"capabilities":{"supports_vision":true,"supports_tools":true,"supports_reasoning":true,"context_window":200000,"max_output_tokens":32000,"model_family":"gpt-5"}}
    """

    private static let logs = """
    {"file":"dashboard.log","lines":["2026-06-08T09:20:00Z INFO dashboard started for fixture profile","2026-06-08T09:20:01Z INFO loaded 4 fixture sessions","2026-06-08T09:20:02Z INFO gateway state: running"]}
    """

    private static let memory = """
    {"active":"","providers":[{"name":"","description":"Built-in MEMORY.md and USER.md files","configured":true},{"name":"memory-vector","description":"Vector-backed memory plugin","configured":false}],"builtin_files":{"memory":640,"user":384}}
    """

    private static let env = """
    {
      "OPENAI_API_KEY":{"is_set":true,"redacted_value":"sk-...fixture","description":"OpenAI API key used by the fixture provider.","url":"https://platform.openai.com/api-keys","category":"provider","is_password":true,"tools":[],"advanced":false},
      "SLACK_BOT_TOKEN":{"is_set":true,"redacted_value":"xoxb-...fixture","description":"Slack bot token for gateway messaging.","url":null,"category":"messaging","is_password":true,"tools":[],"advanced":false},
      "HERMES_LOG_LEVEL":{"is_set":true,"redacted_value":"info","description":"Log level for Hermes services.","url":null,"category":"setting","is_password":false,"tools":[],"advanced":false}
    }
    """

    private static let configSchema = """
    {"fields":{"model.provider":{"type":"select","description":"Main model provider.","category":"model","options":["openai","anthropic","local"]},"model.default":{"type":"string","description":"Main model identifier.","category":"model"},"gateway.enabled":{"type":"boolean","description":"Enable the gateway service.","category":"gateway"}},"category_order":["model","gateway"]}
    """

    private static let config = """
    {"model":{"provider":"openai","default":"gpt-5.2"},"gateway":{"enabled":true}}
    """

    private static let configDefaults = """
    {"model":{"provider":"openai","default":"gpt-5.2-mini"},"gateway":{"enabled":false}}
    """
}

struct ScreenshotFixtureAdminRunner: HermesAdminRunning {
    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        let joined = command.arguments.joined(separator: " ")
        if joined.contains("doctor") {
            return HermesAdminResult(exitCode: 0, stdout: "OK: fixture dashboard\nOK: fixture gateway\n", stderr: "")
        }
        if joined.contains("update --check") || joined.contains("update") {
            return HermesAdminResult(exitCode: 0, stdout: "Hermes is up to date.\n", stderr: "")
        }
        return HermesAdminResult(exitCode: 0, stdout: "", stderr: "")
    }
}

@MainActor
extension ServerWindowHarness {
    static func makeScreenshotFixture() -> ServerWindowHarness {
        let client = DashboardClient(
            baseURL: ScreenshotFixtures.baseURL,
            token: { "fixture-token" },
            http: ScreenshotFixtureDashboardHTTP()
        )
        let manager = SessionManager(backendFactory: {
            MockChatBackend(sessionId: ScreenshotFixtures.primarySessionID)
        })
        let store = SessionsStore(
            manager: manager,
            adminRunner: ScreenshotFixtureAdminRunner(),
            dashboardClient: client,
            defaultCwd: ScreenshotFixtures.cwd
        )
        let profile = ServerProfile(
            name: "Fixture Server",
            kind: .ssh,
            host: "docs-fixture.local",
            user: "demo",
            port: 22,
            version: HermesVersion(ScreenshotFixtures.version)
        )
        let harness = ServerWindowHarness(store: store, profile: profile)
        harness.dashboardClient = client
        harness.dashboardStarted = true
        harness.liveHermesVersion = HermesVersion(ScreenshotFixtures.version)
        return harness
    }

    func openScreenshotSession() async {
        await store.openExisting(ScreenshotFixtures.primarySessionSummary)
    }
}
