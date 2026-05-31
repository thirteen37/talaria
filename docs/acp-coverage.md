# ACP Coverage

This file tracks which ACP methods and events Talaria handles.

## MVP Required

- `initialize`
- `session/new`
- `session/load`
- `session/prompt`
- `session/cancel`
- text deltas
- reasoning or thinking deltas
- tool start, progress, and completion events
- permission requests
- diff payloads

## Current Coverage

Sprint 2 includes v0.13.2-shaped Swift Codable models for the stable ACP schema, typed JSON-RPC request/response dispatch, typed `session/update` streaming, local `initialize`, `session/new`, `session/prompt`, and `session/cancel` client APIs.

Talaria now handles agent-initiated `session/request_permission` requests with typed permission outcomes, renders tool-call diff payloads in chat, renders markdown text bubbles, surfaces slash commands from `available_commands_update`, and shows local turn status with elapsed time plus the session git branch.

Sprint 3 added `session/load` on `HermesClient` and a `SessionManager` that multiplexes multiple sessions per window. Earlier builds browsed `~/.hermes/state.db` through `HermesDB`; Sprint 7 removed that SQLite path in favor of dashboard session routes. Rename still goes through the `hermes` CLI because the dashboard does not expose a rename route. Delete now uses the dashboard.

## Sprint 4 — Remote SSH

`SSHTransport` now exposes a non-interactive `probeConnectivity(profile:)` helper plus a typed `SSHTransportError` (auth failed, host key mismatch, timeout, unreachable, other). The classifier is reused both by the editor's probe button and by the long-lived ACP transport when it exits unexpectedly.

`HermesProbe` runs `command -v hermes; hermes --version` over either a local shell or SSH and records `HermesProbeResult { binaryPath, version, versionRaw, acpSupported }`. Profiles are persisted via `ProfileStore` (Codable JSON at `~/Library/Application Support/Talaria/profiles.json`). SSH identity files are referenced by path — secrets stay in the user's `~/.ssh`, not in Talaria storage.

Server windows are now keyed by `ServerProfile.id` via `WindowGroup(for: UUID.self)`. The bundled local Hermes lives at a well-known UUID (`ProfileDirectory.localProfileID`) so it's always available without persisting it on disk. Menus expose **New Server Window** and **Recent Servers**.

Remote browsing now uses the dashboard over a system-ssh loopback port forward. The old `RemoteSnapshot` + `sqlite3 .backup` + `sftp` pipeline was removed with the mandatory dashboard conversion.

## Sprint 5 — Management surfaces

The six `Talaria/Manage/*View.swift` placeholders were first backed by `HermesAdmin` runners in Sprint 5. Sprint 7 moved Skills, Cron, Logs, and Updates to dashboard routes, leaving `HermesAdmin` as the fallback for Tools and Doctor.

- **Skills**: dashboard `GET /api/skills` and `PUT /api/skills/toggle`.
- **Tools** (`HermesTools`): CLI list / enable / disable remains because the dashboard has no toggle route.
- **Cron**: dashboard CRUD over `/api/cron/jobs`.
- **Logs**: dashboard polling over `/api/logs`, with client-side tail-diffing to avoid repeated lines.
- **Doctor** (`HermesDoctor`): one-shot `hermes doctor`, with a section splitter that recognises `== Title ==`, `--- Title ---`, and ALL-CAPS standalone headers. "Copy diagnostic bundle" puts the raw report + Talaria version + profile summary on the clipboard.
- **Updates**: dashboard status + action polling over `/api/status`, `/api/hermes/update`, and `/api/actions/hermes-update/status`.
- **Capability gating**: `CapabilityTable.has(_:in:)` reads fluently at view call sites and surfaces feature absence as a banner rather than a crash.

## Sprint 6 — Capability minimums

Sprint 6 added version pins for ACP and CLI capabilities. Sprint 7 collapsed the management dashboard requirements into one `requiresDashboard` capability:

| Capability | Min Hermes | First tag |
| --- | --- | --- |
| `acp` / `permissions` / `diffs` | `0.3.0` | `v2026.3.17` |
| `toolsEnablePerPlatform` | `0.4.0` | `v2026.3.23` |
| `requiresDashboard` | `0.14.0` | `v2026.5.16` |

Dashboard-backed surfaces check `requiresDashboard` against the profile's probed Hermes version and render an orange warning banner when the pin is not met; hard runtime errors still take precedence as red banners. `ToolsView` still checks `toolsEnablePerPlatform` because it remains on the CLI path.

## Sprint 7 — Mandatory dashboard

Sprint 7 makes the Hermes dashboard HTTP API (`hermes dashboard`, FastAPI/Uvicorn on `127.0.0.1:<ephemeral>`) a hard prerequisite for every non-chat surface. The SQLite snapshot path, the Rich-output scrapers for Skills / Cron / Logs / Updates, and the per-route capability flags they gated were removed:

- Deleted `HermesDB.swift`, `RemoteSnapshot.swift`, `RemoteSnapshotTransfer.swift`, `HermesSkills.swift`, `HermesCron.swift`, `HermesLogs.swift`, `HermesUpdates.swift` (and their tests / fixtures).
- Collapsed `cronCRUD` / `updateCheck` / `skillsToggle` and the five per-route `dashboard*API` flags into a single `requiresDashboard` capability pinned at Hermes 0.14.0.
- Added `DashboardClient` (URLSession, retry-on-401), `DashboardSession` (token cache scraped from `GET /`), `DashboardSpawnSpec` (local + remote-via-ssh-`-L`), `DashboardSupervisor` (refcounted spawn + reachability poll + missing-`[web]` detection), `SystemDashboardProcessLauncher`, and `DashboardPortAllocator`.
- `DashboardCoordinator` in `Talaria/Windows/ServerWindow.swift` owns one supervisor per profile, shared across windows.
- `DoctorView` shows two prereq probes — `Hermes ≥ 0.14.0` and "Dashboard reachable" — alongside the CLI-driven `hermes doctor` report.

> **Reverted (Updates only):** the Updates surface was moved back to the
> `hermes update --check` CLI path — the dashboard `GET /api/status` reports
> only `version` + `release_date`, with no commits-behind / update-available
> signal, so it can't report a source install being behind `origin/main`.
> `HermesUpdates.swift` and the `updateCheck` capability (pinned at Hermes
> 0.12.0) are restored; the short-lived `DashboardUpdatesService` is removed.

Dashboard coverage today (Hermes 0.14.0 / release 2026.5.16):

| Surface | Dashboard route(s) |
| --- | --- |
| Sessions browse / search | `GET /api/sessions`, `GET /api/sessions/search` |
| Sessions read / delete | `GET /api/sessions/{id}`, `DELETE /api/sessions/{id}` |
| Sessions rename | _no route — still on `hermes sessions rename` CLI_ |
| Updates | `GET /api/status` + `POST /api/hermes/update` + `GET /api/actions/hermes-update/status` |
| Skills | `GET /api/skills`, `PUT /api/skills/toggle` |
| Cron | full CRUD on `/api/cron/jobs` + `/pause` + `/resume` + `/trigger` |
| Logs | polled `GET /api/logs` (`file`, `lines`, `level`, `component`, `search` query params) |
| Profiles config editor | `GET /api/config/schema`, `GET /api/config`, `PUT /api/config`, `GET /api/profiles` (plus per-profile scoping via `hermes -p <name> dashboard`) |
| Tools enable/disable | _no toggle route — still on `hermes tools enable/disable` CLI_ |
| Doctor | _no `/api/doctor` — still on `hermes doctor` CLI_ |
| Chat | _stays on ACP/JSON-RPC, not the dashboard_ |

iOS dashboard mode is deferred until NIO-SSH port forwarding lands; today the iOS surface only exercises ACP chat.
