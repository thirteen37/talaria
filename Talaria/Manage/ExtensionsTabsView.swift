import HermesKit
import SwiftUI

/// Consolidates the four "extend what the agent can do" surfaces — Skills,
/// Tools, MCP Servers, and Plugins — behind a single **Skills, Tools, MCP,
/// Plugins** sidebar/Browse entry. A thin `TabbedDestinationView` wrapper that
/// forwards the inputs `BrowseDetailView` already has on hand to the four
/// existing views unchanged. Each child keeps its own `.navigationTitle` and
/// capability gating, so the detail title tracks the active tab.
struct ExtensionsTabsView: View {
    let harness: ServerWindowHarness

    var body: some View {
        TabbedDestinationView(tabForFocus: { ref in
            switch ref {
            case .skill: return "skills"
            case .tool: return "tools"
            case .mcpServer: return "mcp"
            case .plugin: return "plugins"
            default: return nil
            }
        }, tabs: [
            DestinationTab(id: "skills", title: "Skills", systemImage: "sparkles") {
                SkillsView(
                    client: harness.dashboardClient,
                    runner: harness.store.adminRunner,
                    hermesVersion: harness.effectiveHermesVersion,
                    hermesHome: harness.profile.hermesHome
                )
            },
            DestinationTab(id: "tools", title: "Tools", systemImage: "wrench.and.screwdriver") {
                ToolsView(
                    client: harness.dashboardClient,
                    runner: harness.store.adminRunner,
                    hermesVersion: harness.effectiveHermesVersion
                )
            },
            DestinationTab(id: "mcp", title: "MCP Servers", systemImage: "server.rack") {
                MCPServersView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
            },
            DestinationTab(id: "plugins", title: "Plugins", systemImage: "puzzlepiece.extension") {
                PluginsView(client: harness.dashboardClient, hermesVersion: harness.effectiveHermesVersion)
            },
        ])
    }
}
