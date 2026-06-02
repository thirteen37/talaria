# Integration Coverage

This file tracks the Hermes surfaces Talaria currently depends on. It is
organized by integration boundary rather than release stage so it stays useful
as ACP, dashboard routes, and CLI fallbacks evolve independently.

## Integration Boundaries

Talaria talks to Hermes through four channels:

- **ACP / JSON-RPC** for live chat sessions.
- **Dashboard HTTP** for durable state and management screens.
- **Hermes CLI fallbacks** where the dashboard does not expose a route yet.
- **Embedded TUI (PTY)** for rendering `hermes chat --tui` inline as an alternative to native ACP chat (macOS only).

Talaria does not read or write Hermes SQLite files directly.

## Capability Gates

| Capability | Min Hermes | First tag | Used for |
| --- | --- | --- | --- |
| `acp` | `0.3.0` | `v2026.3.17` | Live chat over ACP / JSON-RPC |
| `permissions` | `0.3.0` | `v2026.3.17` | Agent permission requests and user decisions |
| `diffs` | `0.3.0` | `v2026.3.17` | Tool-call diff payload rendering |
| `updateCheck` | `0.12.0` | `v2026.4.30` | `hermes update --check` CLI fallback |
| `toolsEnablePerPlatform` | `0.4.0` | `v2026.3.23` | `hermes tools enable/disable/list` CLI fallback |
| `requiresDashboard` | `0.14.0` | `v2026.5.16` | Dashboard-backed sessions, management, config, logs, plugins, and kanban |
| `requiresModelAPI` | `0.14.0` | `v2026.5.16` | `/api/model/*` (main + auxiliary model assignment) |
| `requiresEnvAPI` | `0.14.0` | `v2026.5.16` | `/api/env*` (Environment screen `.env` CRUD) |
| `requiresMCPAPI` | `0.15.1` | (untagged) | `/api/mcp/*` (MCP Servers screen: registry CRUD + catalog) |

Dashboard-backed screens render a warning banner when `requiresDashboard` is
not met. Profiles still load and ACP chat can still run; non-chat dashboard
surfaces remain unavailable until `hermes dashboard` can be started and reached.

## ACP Coverage

ACP remains the live-session transport. `HermesClient` and `SessionManager`
cover:

- `initialize`
- `session/new`
- `session/load`
- `session/prompt`
- `session/cancel`
- typed `session/update` streaming
- text deltas
- reasoning / thinking deltas
- tool start, progress, and completion events
- `session/request_permission` with typed permission outcomes
- tool-call diff payloads
- `available_commands_update` for slash command suggestions

The chat UI renders markdown text bubbles, tool-call state, diff payloads, local
turn status with elapsed time, and the active session git branch.

## Dashboard Coverage

Talaria treats `hermes dashboard --no-open --host 127.0.0.1 --port <port>` as
the source of truth for non-chat state. `DashboardSupervisor` starts the process,
polls reachability, extracts and refreshes the session token, reference-counts
window consumers, and tears the child down when the last consumer releases it.

| Surface | Dashboard route(s) |
| --- | --- |
| Status / version / gateway read state | `GET /api/status` |
| Sessions browse / search | `GET /api/sessions`, `GET /api/sessions/search` |
| Sessions read / messages / delete | `GET /api/sessions/{id}`, `GET /api/sessions/{id}/messages`, `DELETE /api/sessions/{id}` |
| Skills | `GET /api/skills`, `PUT /api/skills/toggle` |
| Plugins | `GET /api/dashboard/plugins/hub`, `POST /api/dashboard/agent-plugins/install`, `POST /api/dashboard/agent-plugins/{name}/enable`, `POST /api/dashboard/agent-plugins/{name}/disable`, `POST /api/dashboard/agent-plugins/{name}/update`, `DELETE /api/dashboard/agent-plugins/{name}`, `PUT /api/dashboard/plugin-providers` |
| Cron | `GET` / `POST` on `/api/cron/jobs`, `PUT` / `DELETE` on `/api/cron/jobs/{id}`, plus `/pause`, `/resume`, and `/trigger` |
| Kanban | `/api/plugins/kanban/*` — boards, tasks (full CRUD + bulk), links, comments, run logs, diagnostics, stats, assignees |
| Models | `GET /api/model/options`, `GET /api/model/auxiliary`, `POST /api/model/set` (main + auxiliary slots) |
| Logs | `GET /api/logs` with `file`, `lines`, `level`, `component`, and `search` query parameters |
| Profiles | `GET` / `POST` on `/api/profiles`, `PATCH` / `DELETE` on `/api/profiles/{name}` |
| Config editor | `GET /api/config/schema`, `GET /api/config`, `PUT /api/config` |
| Soul editor | `GET /api/profiles/{profile}/soul`, `PUT /api/profiles/{profile}/soul` (profile-scoped; no top-level `/api/soul`) |
| Personalities editor | `agent.personalities` via the config editor (`GET`/`PUT /api/config`) |
| Environment (.env) | `GET /api/env`, `PUT /api/env`, `DELETE /api/env`, `POST /api/env/reveal` |
| MCP servers | `GET`/`POST /api/mcp/servers`, `POST /api/mcp/servers/{name}/test`, `PUT /api/mcp/servers/{name}/enabled`, `DELETE /api/mcp/servers/{name}`, `GET /api/mcp/catalog`, `POST /api/mcp/catalog/install` (gated on `requiresMCPAPI` ≥ `0.15.1`) |

The default server window shares one dashboard per `ServerProfile`. Profile
editing can acquire additional scoped dashboards with `hermes -p <name>
dashboard` so reads and writes apply to the selected Hermes profile. On macOS,
remote dashboard access uses system SSH with a loopback `-L` forward. On iOS,
remote dashboard HTTP travels over the pure-Swift NIO-SSH `direct-tcpip` tunnel
owned by the window.

## CLI Fallbacks

These operations still run through the Hermes CLI because Talaria does not have
dashboard routes for them yet:

| Surface | CLI command |
| --- | --- |
| Session rename | `hermes sessions rename` |
| Updates check / apply | `hermes update --check`, `hermes update` |
| Tools list / enable / disable | `hermes tools list`, `hermes tools enable`, `hermes tools disable` |
| Doctor report / fix | `hermes doctor`, `hermes doctor --fix` |
| Gateway lifecycle writes | `hermes gateway start`, `stop`, `restart`, `install`, `uninstall` |

The CLI runners are profile-scoped, so windows using a named Hermes profile pass
the matching `-p <name>` context for fallback commands.

Updates intentionally use the CLI path rather than the dashboard update action:
`GET /api/status` reports only the installed version and release date, while
`hermes update --check` can report source installs that are behind `origin/main`.

## Terminal (TUI) Sessions

A chat can be launched as the real Hermes TUI inside an embedded terminal
emulator (SwiftTerm), instead of the native ACP renderer. This path bypasses
both ACP and the dashboard: Talaria spawns `hermes chat --tui` directly in a PTY
and renders its raw output. macOS only — iOS has no local-process/PTY path.

| Surface | Hermes CLI command |
| --- | --- |
| New TUI chat | `hermes [-p <name>] chat --tui` |
| Resume as TUI | `hermes [-p <name>] chat --tui -r <id>` |

- **Local** profiles run the command via `env` with the login-shell PATH and
  `HERMES_HOME`, and the session cwd as the process working directory.
- **Remote** profiles always use system `ssh -tt` (PTY), even when the macOS
  NIO-SSH ACP opt-in is enabled — the NIO transport cannot drive a local-process
  terminal view.

The command builder is pure and unit-tested (`HermesKit` `TUILaunchSpec.swift`).
SwiftTerm is a macOS-app-target-only dependency. Only one mode runs per session
id at a time (TUI and inline ACP are mutually exclusive for the same session).

## Known Gaps

- Dashboard route for session rename.
- Dashboard update status that reports commits-behind / update-available state.
- Dashboard route for tools enable / disable.
- Dashboard route for doctor report and doctor fix.
- Dashboard lifecycle write routes for gateway start / stop / restart /
  install / uninstall.
