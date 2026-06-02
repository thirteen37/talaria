# Talaria Roadmap

This document preserves the larger product surface from the Scarf parity research while the first release stays focused on the MVP.

## MVP Boundary

Talaria v1 is a native macOS front-end for Hermes using ACP for live chat and `hermes dashboard` for sessions, logs, skills, cron jobs, and updates. A small set of operations remain on CLI fallbacks until Hermes exposes dashboard routes for them: session rename, tools enable/disable, doctor reports, and gateway lifecycle. Local subprocess and SSH-backed servers are both in scope. Anything below marked "Deferred" is intentionally out of v1 unless it becomes necessary to make the MVP coherent.

## Shipped Since The MVP Boundary

These started as deferred or out-of-scope and have since landed. They are listed
here so the "Deferred" sections below stay an accurate to-do list rather than a
historical one:

- Dedicated **Models** screen: main + auxiliary model assignment, plus custom
  OpenAI-compatible endpoints surfaced from `hermes model` (`custom_providers`).
- **Plugins** install / enable / disable / update via the dashboard.
- **Gateway** process control (start / stop / restart / install / uninstall via CLI).
- **Hermes profile** management (clone / rename / delete).
- **Soul** (`SOUL.md`) and **Personalities** (`agent.personalities`) editors.
- **Environment** screen with `.env` CRUD.
- **Kanban** board (boards + tasks) with full CRUD, backed by the Hermes kanban plugin.
- **Customizable Browse sidebar** — reorder and hide manage pages, shared with the iPhone Browse sheet.
- iOS app target (shared source tree, in progress) with a NIO-SSH dashboard tunnel.

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

- Native setup forms for all messaging platforms (gateway *process* control already shipped; per-platform credential/config forms have not).
- MCP server registry with browse, add, edit, and curated preset flows.
- Memory and user-profile editors for `MEMORY.md` and `USER.md` (the `SOUL.md` and personality editors already shipped).
- Webhook management.
- Credential pools and token rotation flows.
- Export/import profile bundles.
- Profile snapshot and restore.
- Jumphost template UI.

## Deferred Management

- Skills Hub category **browser** (in-app search + install/update/remove shipped:
  search uses the public Nous index over HTTP, mutations use the `hermes skills`
  CLI fallback. Caveat: v0.14.0 `hermes skills uninstall` has no `--yes`, so
  remove feeds `y\n` on stdin and **remote** uninstall is deferred until a future
  Hermes adds the flag or the NIO/SSH runners forward stdin).
- Pre-run script editor for cron jobs.
- Delivery-failure dashboard for scheduled runs.
- Structured log explorer with session-id pills and deep links.
- Component drill-down inspectors for `hermes doctor`.
- Dashboard routes for session rename, tools enable/disable, and doctor reports.
- Inline release notes and update channel selection.
- Hermes Proxy (the OpenAI-compatible local proxy; gateway process control already shipped).
- Project dashboards beyond the Kanban board (custom widgets, charts, embedded webviews).

## Deferred Packaging And Distribution

- Mac App Store distribution.
- iOS companion app. ACP has a pure-Swift transport seam, but dashboard mode still needs NIO-backed port forwarding, Keychain-backed identity, and an iOS UI target.
- Relay transport for sshd-less environments (containers without sshd). Plain iOS no longer needs a relay.
- Import/export tooling for full application state.

## Scarf Parity Catalogue

The long-term IA remains Monitor, Interact, Configure, Manage, and Projects:

- Monitor: dashboard, sessions, activity, insights.
- Interact: live chat, memory, skills.
- Configure: platforms, personality, quick commands, credentials, plugins, webhooks, profiles, Hermes Proxy.
- Manage: tools, MCP servers, gateway, cron jobs, health, logs, settings.
- Projects: project dashboards, project-scoped session lists, and repository-specific controls.

These are carried forward as research input, not as hidden v1 requirements.
