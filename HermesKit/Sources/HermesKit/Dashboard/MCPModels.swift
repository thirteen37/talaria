import Foundation

// Codable models for the Hermes dashboard **MCP server** routes
// (`/api/mcp/*`), used by the native "MCP Servers" management surface. The
// shapes mirror `hermes_cli/web_server.py`'s `_mcp_server_summary`,
// `test_mcp_server`, and `list_mcp_catalog` handlers (verified against the
// Hermes source — the wire keys are plain single words, no snake_case, except
// the catalog entry's `auth_type` / `required_env` / `needs_install`).
//
// These are deliberately **separate** from the ACP `McpServer*` /
// `EnvVariable` / `HttpHeader` types in `ACP/Schema.swift`: those carry the ACP
// `type` discriminator + `_meta` shape and a list-of-`{name,value}` env, used
// when launching a session. The dashboard registry uses a dict `env` and a
// derived `transport` string, so it gets its own models.

// MARK: - Transport (UI draft)

/// Transport selected when *adding* a server. The dashboard's create body
/// (`MCPServerCreate`) has no transport discriminator — it infers stdio from a
/// `command` and a remote server from a `url` — so the app only needs to
/// distinguish "local stdio" from "remote URL". Remote covers both streamable
/// HTTP and SSE (Hermes negotiates which at connect time), so there's no
/// separate `.sse` case: it would send the identical body.
public enum MCPTransport: String, Codable, Sendable, CaseIterable, Identifiable {
    case stdio
    case http

    public var id: String { rawValue }
}

// MARK: - Server

/// One configured MCP server from `GET /api/mcp/servers` (the `servers` array)
/// or the body echoed by `POST /api/mcp/servers`. `env` values are redacted
/// server-side. `transport` is computed by Hermes as `"http"` (has a `url`),
/// `"stdio"` (has a `command`), or `"unknown"`.
public struct DashboardMCPServer: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    /// `"http"` | `"stdio"` | `"unknown"` — derived server-side from url-vs-command.
    public let transport: String?
    public let url: String?
    public let command: String?
    public let args: [String]?
    /// Redacted `KEY: value` env block (stdio servers). Values are masked.
    public let env: [String: String]?
    /// `"oauth"` | `"header"` | nil — remote-server auth style.
    public let auth: String?
    public let enabled: Bool
    /// Tool-selection allowlist: the enabled tool names, or nil = all tools.
    /// (NOT a tool count — the list route doesn't report one.)
    public let tools: [String]?

    public var id: String { name }

    public init(
        name: String,
        transport: String? = nil,
        url: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        auth: String? = nil,
        enabled: Bool = true,
        tools: [String]? = nil
    ) {
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.auth = auth
        self.enabled = enabled
        self.tools = tools
    }
}

// MARK: - Test connection

/// `POST /api/mcp/servers/{name}/test` payload — connects, lists tools,
/// disconnects. `ok == false` carries an `error` and an empty `tools` list.
public struct DashboardMCPTestResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let tools: [DashboardMCPTool]
    public let error: String?

    public init(ok: Bool, tools: [DashboardMCPTool] = [], error: String? = nil) {
        self.ok = ok
        self.tools = tools
        self.error = error
    }
}

/// One tool reported by a test connection (`{name, description}`).
public struct DashboardMCPTool: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String?

    public var id: String { name }

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

// MARK: - Catalog

/// One entry from `GET /api/mcp/catalog` (the `entries` array) — a
/// Nous-approved MCP from the `optional-mcps/` manifests, with its install /
/// enabled state so the UI can show it inline.
public struct DashboardMCPCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String?
    public let source: String?
    /// Manifest transport type (`entry.transport.type`).
    public let transport: String?
    /// `"oauth"` | `"header"` | `"none"`.
    public let authType: String?
    /// Env vars the user must supply (names + prompts only, never values).
    public let requiredEnv: [DashboardMCPRequiredEnv]?
    /// True when installing needs a git bootstrap (runs as a background action).
    public let needsInstall: Bool?
    public let installed: Bool?
    public let enabled: Bool?

    public var id: String { name }

    public init(
        name: String,
        description: String? = nil,
        source: String? = nil,
        transport: String? = nil,
        authType: String? = nil,
        requiredEnv: [DashboardMCPRequiredEnv]? = nil,
        needsInstall: Bool? = nil,
        installed: Bool? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.transport = transport
        self.authType = authType
        self.requiredEnv = requiredEnv
        self.needsInstall = needsInstall
        self.installed = installed
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case name, description, source, transport, installed, enabled
        case authType = "auth_type"
        case requiredEnv = "required_env"
        case needsInstall = "needs_install"
    }
}

/// One required-env declaration on a catalog entry (`{name, prompt, required}`).
public struct DashboardMCPRequiredEnv: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let prompt: String?
    public let required: Bool?

    public var id: String { name }

    public init(name: String, prompt: String? = nil, required: Bool? = nil) {
        self.name = name
        self.prompt = prompt
        self.required = required
    }
}

/// `POST /api/mcp/catalog/install` result. Git-bootstrap entries return
/// `background == true` with an `action` log id; synchronous installs return
/// `background == false`.
public struct DashboardMCPInstallResult: Codable, Equatable, Sendable {
    public let ok: Bool
    public let name: String?
    public let background: Bool?
    public let action: String?

    public init(ok: Bool, name: String? = nil, background: Bool? = nil, action: String? = nil) {
        self.ok = ok
        self.name = name
        self.background = background
        self.action = action
    }
}
