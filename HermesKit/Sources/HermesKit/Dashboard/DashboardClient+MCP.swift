import Foundation

// Client methods for the Hermes dashboard **MCP server** routes
// (`/api/mcp/*`). Split out of `DashboardClient.swift` like the Kanban surface,
// reusing the internal `get` / `sendDecoding` / `sendNoContent` plumbing. The
// route shapes mirror `hermes_cli/web_server.py` (verified against source):
// the list and catalog responses are wrapped (`{servers:[…]}` / `{entries:[…]}`),
// add echoes the server summary, and test returns `{ok, tools, error?}`.
public extension DashboardClient {
    // MARK: - Servers

    /// `GET /api/mcp/servers` → `{servers:[…]}`. Returns the unwrapped array.
    func listMCPServers() async throws -> [DashboardMCPServer] {
        let response: MCPServersResponse = try await get(path: "/api/mcp/servers")
        return response.servers
    }

    /// `POST /api/mcp/servers`. The body carries either a `url` (remote server)
    /// or a `command` (+`args`, +`env`) for stdio; `auth` is the remote auth
    /// style (`"oauth"`/`"header"`). nil/empty optionals are omitted via the
    /// synthesized `encodeIfPresent`. The route echoes the created server.
    @discardableResult
    func addMCPServer(
        name: String,
        url: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        auth: String? = nil
    ) async throws -> DashboardMCPServer {
        let body = MCPServerCreateBody(
            name: name,
            url: url,
            command: command,
            args: args,
            env: env,
            auth: auth
        )
        return try await sendDecoding(method: "POST", path: "/api/mcp/servers", body: body)
    }

    /// `POST /api/mcp/servers/{name}/test` — connect, list tools, disconnect.
    /// A reachable-but-failing probe still returns 200 with `ok:false`+`error`.
    func testMCPServer(name: String) async throws -> DashboardMCPTestResult {
        try await sendDecoding(method: "POST", path: "/api/mcp/servers/\(name)/test")
    }

    /// `PUT /api/mcp/servers/{name}/enabled`, body `{enabled}`.
    func setMCPServerEnabled(name: String, enabled: Bool) async throws {
        try await sendNoContent(
            method: "PUT",
            path: "/api/mcp/servers/\(name)/enabled",
            body: MCPEnabledBody(enabled: enabled)
        )
    }

    /// `DELETE /api/mcp/servers/{name}`.
    func deleteMCPServer(name: String) async throws {
        try await sendNoContent(method: "DELETE", path: "/api/mcp/servers/\(name)")
    }

    // MARK: - Catalog

    /// `GET /api/mcp/catalog` → `{entries:[…], diagnostics:[…]}`. Returns the
    /// unwrapped entry array (diagnostics are dropped — they're catalog-author
    /// warnings, not user-actionable here).
    func listMCPCatalog() async throws -> [DashboardMCPCatalogEntry] {
        let response: MCPCatalogResponse = try await get(path: "/api/mcp/catalog")
        return response.entries
    }

    /// `POST /api/mcp/catalog/install`, body `{name, env, enable}`. Returns the
    /// install status (`background:true` for git-bootstrap entries that run as a
    /// detached action).
    @discardableResult
    func installMCPCatalogEntry(
        name: String,
        env: [String: String]? = nil,
        enable: Bool = true
    ) async throws -> DashboardMCPInstallResult {
        let body = MCPCatalogInstallBody(name: name, env: env, enable: enable)
        return try await sendDecoding(method: "POST", path: "/api/mcp/catalog/install", body: body)
    }

    /// Status of a detached install action — `install` returns `background:true`
    /// for git-bootstrap catalog entries and runs the clone as the `mcp-install`
    /// action, whose progress is readable here (mirrors the hermes-update action
    /// status route). Poll until `running == false`, then refresh.
    func mcpActionStatus(action: String = "mcp-install") async throws -> DashboardActionStatus {
        try await get(path: "/api/actions/\(action)/status")
    }
}

// MARK: - Request bodies & response wrappers

private struct MCPServersResponse: Decodable {
    let servers: [DashboardMCPServer]
}

private struct MCPCatalogResponse: Decodable {
    let entries: [DashboardMCPCatalogEntry]
}

private struct MCPServerCreateBody: Encodable {
    let name: String
    let url: String?
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let auth: String?
}

private struct MCPEnabledBody: Encodable {
    let enabled: Bool
}

private struct MCPCatalogInstallBody: Encodable {
    let name: String
    let env: [String: String]?
    let enable: Bool
}
