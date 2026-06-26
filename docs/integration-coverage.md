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

One surface also talks to a service *outside* Hermes:

- **Hindsight REST API (direct)** — read-only memory browse/search when Hindsight is the active memory provider. Hermes exposes no route to browse Hindsight's vector store (`GET /api/memory` is status-only), so Talaria calls Hindsight's own `/v1/{tenant}/banks/{bank}/…` API directly — `http://127.0.0.1:<port>` for the local-embedded daemon (no auth), or the configured `api_url` + `HINDSIGHT_API_KEY` for cloud / local_external. See **Hindsight Browse**.

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
| Memory (provider status) | `GET /api/memory` — read-only active provider + sizes only. The `MEMORY.md` / `USER.md` **text** has no route; it is edited direct-disk (see **Direct File I/O**). When `active == "hindsight"`, a **Hindsight** browse tab appears that calls Hindsight's API directly (see **Hindsight Browse**). The provider picker uses `PUT /api/memory/provider` (Plugins). |
| MCP servers | `GET`/`POST /api/mcp/servers`, `POST /api/mcp/servers/{name}/test`, `PUT /api/mcp/servers/{name}/enabled`, `DELETE /api/mcp/servers/{name}`, `GET /api/mcp/catalog`, `POST /api/mcp/catalog/install` (gated on `requiresMCPAPI` ≥ `0.15.1`) |

The server window shares one dashboard per `ServerProfile`. Cross-profile reads
and writes (the Sync screen, the config editor's compare/named-profile edit)
scope that single dashboard per request via a `?profile=<name>` query param
(`DashboardClient.scoped(toProfile:)`) — the dashboard applies a context-local
`HERMES_HOME` override so the request lands in the selected profile's home. (No
separate `hermes -p <name> dashboard` is spawned; newer Hermes ignores `-p` for
the dashboard's own request scoping.) On macOS, remote dashboard access uses
system SSH with a loopback `-L` forward. On iOS, remote dashboard HTTP travels
over the pure-Swift NIO-SSH `direct-tcpip` tunnel owned by the window.

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
| Hindsight browse (endpoint resolution) | read | `hindsight/config.json` (`profiles/<name>/…` for a named profile; legacy fallback `~/.hindsight/config.json`), `~/.hindsight/profiles/metadata.json` | Read-only, to resolve the Hindsight REST endpoint (mode, `api_url`, `bank_id`/`bank_id_template`, embedded profile→port). No mutation. `HindsightEndpointResolver` wraps `HermesFileStore`. See **Hindsight Browse**. |

These are the only direct-file paths; Talaria still never touches Hermes SQLite
files directly.

## Hindsight Browse

When the active memory provider is **Hindsight**, the Memory destination grows a
read-only **Hindsight** tab that browses and searches the provider's stored
memories. Hermes has no route for this (the `hindsight-client` SDK it uses calls
only `retain`/`recall`/`reflect`), so Talaria talks to Hindsight's REST API
directly — the same FastAPI server (`hindsight-api`) backs Hindsight Cloud and
the local-embedded daemon, exposing one shared `/v1/{tenant}/banks/{bank}/…`
surface.

| Operation | Route |
| --- | --- |
| List (newest-first, paginated, optional `q` full-text) | `GET /v1/default/banks/{bank}/memories/list?limit=&offset=&q=` |
| Search (semantic / multi-strategy) | `POST /v1/default/banks/{bank}/memories/recall` |

A memory's `tags` are classified by namespace (`HindsightTagRef`). Hermes tags
retains with lineage refs `session:<id>` (the session it was retained in) and
`parent:<id>` (the parent session it was resumed/forked from) — **both are Hermes
session ids**, so each deep-links to its chat via the shared
`EntityLink`/`EntityRef.session`. Other tags render inert.

Endpoint resolution (`HindsightEndpointResolver` → `HindsightEndpoint`):

- **local_embedded** (primary target): base URL `http://127.0.0.1:<port>`, **no
  auth**. Port is `8888` for the literal `default` profile, else read from
  `~/.hindsight/profiles/metadata.json` for the configured embedded profile
  (default `hermes`).
- **cloud / local_external**: base URL from `api_url` (cloud default
  `https://api.hindsight.vectorize.io`); `Authorization: Bearer <HINDSIGHT_API_KEY>`.
- **bank_id**: the static `bank_id`/`banks.hermes.bankId`, or a `bank_id_template`
  resolved (placeholders sanitized/collapsed) mirroring Hermes.

The client (`HindsightAPIClient`) is read-only — it never calls retain/delete.

**Remote profiles** are supported by tunnelling to the remote daemon's loopback,
reusing the dashboard's SSH forwarding (`HindsightRemoteTransport`):

- **macOS** (`SSHForwardHindsightTransport`): a managed `ssh -L <ephemeral>:127.0.0.1:<remotePort> -N`
  forward (`DashboardSpawnSpec.forward`, same auth/host-key trust as the dashboard);
  the client talks to the local end over `URLSession`. The forward is torn down when
  the surface leaves.
- **iOS** (`NIOHindsightTransport`): a `direct-tcpip` channel on the window's existing
  `NIOSSHDashboardConnection` straight to `127.0.0.1:<remotePort>` (via `NIOSSHDashboardHTTP`),
  no forward process.

The resolver returns a `HindsightResolution` whose `remoteEmbeddedPort` is non-nil for a
remote `local_embedded` daemon (port read from the remote `metadata.json` over SSH); the
view model then opens the platform transport. A remote **cloud** Hindsight needs no tunnel
(config read over SSH; cloud API reachable directly). If no transport is available, the tab
shows `HindsightBrowseError.remoteEmbeddedUnsupported` guidance. Decoding is deliberately
tolerant of the external shape (`text`||`content`, `date`||`timestamp`||`mentioned_at`,
`entities` as string or list).

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
