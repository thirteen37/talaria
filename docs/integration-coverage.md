# Integration Coverage

This file tracks the Hermes surfaces Talaria currently depends on. It is
organized by integration boundary rather than release stage so it stays useful
as the gateway, dashboard routes, and CLI fallbacks evolve independently.

## Integration Boundaries

Talaria talks to Hermes through four channels:

- **Gateway WebSocket (`/api/ws`)** — JSON-RPC 2.0 — for live chat sessions (rides `hermes dashboard`).
- **Dashboard HTTP** for durable state and management screens.
- **Hermes CLI fallbacks** where the dashboard does not expose a route yet.
- **Embedded TUI (PTY)** for rendering `hermes chat --tui` inline as an alternative to native gateway chat (macOS only).

Talaria does not read or write Hermes SQLite files directly.

## Capability Gates

| Capability | Min Hermes | First tag | Used for |
| --- | --- | --- | --- |
| `acp` | `0.3.0` | `v2026.3.17` | Legacy probe flag (`ACP supported` in the capability view). Live chat now rides the dashboard `/api/ws` gateway and no longer gates on this. |
| `permissions` | `0.3.0` | `v2026.3.17` | Agent permission requests and user decisions |
| `diffs` | `0.3.0` | `v2026.3.17` | Tool-call diff payload rendering |
| `updateCheck` | `0.12.0` | `v2026.4.30` | `hermes update --check` CLI fallback |
| `toolsEnablePerPlatform` | `0.4.0` | `v2026.3.23` | `hermes tools enable/disable/list` CLI fallback |
| `requiresDashboard` | `0.14.0` | `v2026.5.16` | Dashboard-backed sessions, management, config, logs, plugins, and kanban |
| `requiresModelAPI` | `0.14.0` | `v2026.5.16` | `/api/model/*` (main + auxiliary model assignment) |
| `requiresEnvAPI` | `0.14.0` | `v2026.5.16` | `/api/env*` (Environment screen `.env` CRUD) |
| `requiresMCPAPI` | `0.15.1` | (untagged) | `/api/mcp/*` (MCP Servers screen: registry CRUD + catalog) |
| `skillsHub` | `0.14.0` | `v2026.5.16` | `hermes skills install/update/uninstall` CLI fallback (search is public HTTP, ungated) |

Dashboard-backed screens render a warning banner when `requiresDashboard` is
not met. Profiles still load, but live chat now rides the dashboard `/api/ws`
gateway, so chat — like every other dashboard surface — is unavailable until
`hermes dashboard` can be started and reached.

## Live Chat Coverage (gateway)

Live chat runs over the dashboard `/api/ws` JSON-RPC gateway — the same path
Hermes Desktop uses. `GatewayChatClient` maps gateway events onto the shared
`HermesNotification` / `SessionUpdate` model and, with `SessionManager`, covers:

- `session.create` / `session.resume` (new + resumed sessions; resumed sessions seed prior history)
- `prompt.submit` / `session.interrupt` (turn submit + cancel)
- `message.delta` text streaming
- `reasoning.delta` / `reasoning.available` thinking streaming
- `tool.start` / `tool.progress` / `tool.complete` events
- `approval.request` / `clarify.request` / `sudo.request` / `secret.request` with typed permission outcomes
- tool-call diff payloads
- `commands.catalog` for slash-command suggestions
- `session.info` for the model badge, git branch, and token-usage gauge

The chat UI renders markdown text bubbles, tool-call state, diff payloads, the
model badge, local turn status with elapsed time, the context/token-usage gauge,
and the active session git branch. (Historical note: chat used to run over a
`hermes acp` subprocess and a bespoke byte-`Transport` stack; that was removed
once the WebSocket path reached parity — see `docs/gateway-chat.md`.)

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
| Skills (list / toggle) | `GET /api/skills`, `PUT /api/skills/toggle` |
| Skills Hub search | `GET https://hermes-agent.nousresearch.com/docs/api/skills-index.json` (public Nous index, not a dashboard route — `SkillsHubCatalog`) |
| Plugins | `GET /api/dashboard/plugins/hub`, `POST /api/dashboard/agent-plugins/install`, `POST /api/dashboard/agent-plugins/{name}/enable`, `POST /api/dashboard/agent-plugins/{name}/disable`, `POST /api/dashboard/agent-plugins/{name}/update`, `DELETE /api/dashboard/agent-plugins/{name}`, `PUT /api/dashboard/plugin-providers` |
| Cron | `GET` / `POST` on `/api/cron/jobs`, `PUT` / `DELETE` on `/api/cron/jobs/{id}`, plus `/pause`, `/resume`, and `/trigger` |
| Kanban | `/api/plugins/kanban/*` — boards, tasks (full CRUD + bulk), links, comments, run logs, diagnostics, stats, assignees |
| Models | `GET /api/model/options`, `GET /api/model/auxiliary`, `POST /api/model/set` (main + auxiliary slots) |
| Usage / Analytics | `GET /api/analytics/usage`, `GET /api/analytics/models` (read-only token/cost/session analytics; gated by `requiresDashboard`, not a separate constant — both routes ship in the same `0.14.0` `web_server.py`) |
| Logs | `GET /api/logs` with `file`, `lines`, `level`, `component`, and `search` query parameters |
| Profiles | `GET` / `POST` on `/api/profiles`, `PATCH` / `DELETE` on `/api/profiles/{name}` |
| Config editor | `GET /api/config/schema`, `GET /api/config`, `PUT /api/config` |
| Soul & Personalities editor | Base `SOUL.md` via `GET`/`PUT /api/profiles/{profile}/soul` (profile-scoped; no top-level `/api/soul`); `agent.personalities` overlays via the config editor (`GET`/`PUT /api/config`) — both in one integrated split view |
| Environment (.env) | `GET /api/env`, `PUT /api/env`, `DELETE /api/env`, `POST /api/env/reveal` (custom-var enumeration is a direct `.env` read — see **Direct File I/O**) |
| Memory (provider status) | `GET /api/memory` — read-only active provider + sizes only. The `MEMORY.md` / `USER.md` **text** has no route; it is edited direct-disk (see **Direct File I/O**). The provider picker uses `PUT /api/memory/provider` (Plugins). |
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
| Skills Hub install / update / remove | `hermes skills install --yes`, `hermes skills update`, `hermes skills uninstall` (stdin `y\n`; local-only, remote deferred) |
| Skills Hub installed / update reads | `hermes skills list`, `hermes skills check` (`COLUMNS=400 NO_COLOR=1`) |
| Doctor report / fix | `hermes doctor`, `hermes doctor --fix` |
| Gateway lifecycle writes | `hermes gateway start`, `stop`, `restart`, `install`, `uninstall` |

The CLI runners are profile-scoped, so windows using a named Hermes profile pass
the matching `-p <name>` context for fallback commands.

Updates intentionally use the CLI path rather than the dashboard update action:
`GET /api/status` reports only the installed version and release date, while
`hermes update --check` can report source installs that are behind `origin/main`.

## Direct File I/O

A few surfaces touch Hermes files directly because no dashboard route exists for
the data they need. All such access goes through the unified `HermesFileStore`
(local `FileManager` for `.local` profiles; the SSH `RemoteSnapshotTransfer` —
NIO `cat`, or system-`sftp` on macOS — for `.ssh`), resolving the same
home-relative paths as the snapshot reader.

| Surface | Direction | File(s) | Notes |
| --- | --- | --- | --- |
| Environment custom-var list | read | `.env` (path from `hermes config env-path`) | Enumerates user-named keys `GET /api/env` omits; redacted preview only. Mutations stay on the dashboard. |
| Memory editor | read **and write** | `memories/MEMORY.md`, `memories/USER.md` (`profiles/<name>/…` for a named profile) | The one direct-**write** exception and the first non-dashboard remote write. Remote writes stream to a temp + atomic rename, reusing the read path's SSH auth + TOFU host-key trust (no new trust surface). `HermesMemoryStore` wraps `HermesFileStore`. The agent co-owns these files, so the editor re-reads before writing and confirms before overwriting an out-of-band change. |

These are the only direct-file paths; Talaria still never touches Hermes SQLite
files directly.

## Terminal (TUI) Sessions

A chat can be launched as the real Hermes TUI inside an embedded terminal
emulator (SwiftTerm), instead of the native gateway-chat renderer. This path
bypasses both the gateway chat path and the dashboard: Talaria spawns
`hermes chat --tui` directly in a PTY and renders its raw output. macOS only —
iOS has no local-process/PTY path.

| Surface | Hermes CLI command |
| --- | --- |
| New TUI chat | `hermes [-p <name>] chat --tui` |
| Resume as TUI | `hermes [-p <name>] chat --tui -r <id>` |

- **Local** profiles run the command via `env` with the login-shell PATH and
  `HERMES_HOME`, and the session cwd as the process working directory.
- **Remote** profiles always use system `ssh -tt` (PTY), even when the macOS
  NIO-SSH opt-in is enabled — the NIO transport cannot drive a local-process
  terminal view.

The command builder is pure and unit-tested (`HermesKit` `TUILaunchSpec.swift`).
SwiftTerm is a macOS-app-target-only dependency. Only one mode runs per session
id at a time (TUI and inline gateway chat are mutually exclusive for the same session).

## Known Gaps

- Dashboard route for session rename.
- Dashboard update status that reports commits-behind / update-available state.
- Dashboard route for tools enable / disable.
- Dashboard route for doctor report and doctor fix.
- Dashboard lifecycle write routes for gateway start / stop / restart /
  install / uninstall.
