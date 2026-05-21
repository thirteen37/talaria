# Talaria Roadmap

This document preserves the larger product surface from the Scarf parity research while the first release stays focused on the MVP.

## MVP Boundary

Talaria v1 is a native macOS front-end for Hermes using ACP for live chat, read-only SQLite for session browsing, and Hermes CLI commands for administrative writes. Local subprocess and SSH-backed servers are both in scope. Anything below marked "Deferred" is intentionally out of v1 unless it becomes necessary to make the MVP coherent.

## Deferred Chat And Interaction

- Theme and skin switching.
- Mouse-mode toggles and terminal-style banner section pickers.
- Subagent observability tree exposed through `/agents`.
- Activity feed, insights, token analytics, and usage charts.
- `/compress` focus sheet and transcript compaction UI.
- Optional terminal escape hatch for unported TUI features.
- JSONL export, lineage visualization, and branch/fork UI.
- Custom quick commands and command palette extensions beyond MVP slash completion.

## Deferred Configuration

- Native platform and gateway configuration for all messaging platforms.
- MCP server registry with browse, add, edit, and curated preset flows.
- Memory, user profile, and personality editors for `MEMORY.md`, `USER.md`, and `SOUL.md`.
- Plugin install/update workflows.
- Webhook management.
- Credential pools and token rotation flows.
- Export/import profile bundles.
- Profile snapshot and restore.
- Jumphost template UI.

## Deferred Management

- Skills Hub category browser and install/update support.
- Pre-run script editor for cron jobs.
- Delivery-failure dashboard for scheduled runs.
- Structured log explorer with session-id pills and deep links.
- Component drill-down inspectors for `hermes doctor`.
- Inline release notes and update channel selection.
- Hermes Proxy and gateway process control.
- Project dashboards.

## Deferred Packaging And Distribution

- Mac App Store distribution.
- iOS companion app.
- Relay transport for iOS or environments where system `ssh` is unavailable.
- Import/export tooling for full application state.

## Scarf Parity Catalogue

The long-term IA remains Monitor, Interact, Configure, Manage, and Projects:

- Monitor: dashboard, sessions, activity, insights.
- Interact: live chat, memory, skills.
- Configure: platforms, personality, quick commands, credentials, plugins, webhooks, profiles, Hermes Proxy.
- Manage: tools, MCP servers, gateway, cron jobs, health, logs, settings.
- Projects: project dashboards, project-scoped session lists, and repository-specific controls.

These are carried forward as research input, not as hidden v1 requirements.
