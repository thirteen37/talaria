# Architecture

Talaria is a SwiftUI macOS app backed by a shared `HermesKit` Swift package. The app renders Hermes natively instead of embedding the TUI. Live sessions speak ACP over newline-delimited JSON-RPC frames.

## Core Packages

- `ACP`: Codable JSON-RPC and ACP schema types.
- `Transport`: bidirectional byte streams for local processes, SSH processes, and in-memory tests.
- `Client`: request correlation and session lifecycle orchestration.
- `Dashboard`: HTTP client, token/session handling, dashboard process supervision, spawn specs, and update polling.
- `Hermes`: CLI fallbacks, version parsing, doctor/tool parsers, and capability gates.
- `Profiles`: local and SSH server profiles.

## Read And Write Model

Live chat stays on ACP over newline-delimited JSON-RPC. Non-chat surfaces are backed by the Hermes dashboard HTTP API (`hermes dashboard --host 127.0.0.1 --port <port>`). Talaria allocates an ephemeral loopback port by default, but profiles can pin a dashboard port when the automatic choice conflicts with local or remote host policy. Talaria never reads or writes Hermes SQLite files directly.

Each window acquires a dashboard endpoint for its `ServerProfile` through `DashboardSupervisor`. The supervisor starts `hermes dashboard`, polls `/api/status`, caches the session token scraped from the dashboard SPA, reference-counts consumers, and terminates the child when the last window releases it.

The full route table Talaria depends on — auth header, error model, the SPA catch-all trap, and per-route bodies/shapes — is documented in `docs/dashboard-api.md`.

Dashboard-backed surfaces today:

- Sessions browse/search/read/delete: `/api/sessions`, `/api/sessions/search`, `/api/sessions/{id}`.
- Skills: `/api/skills`, `/api/skills/toggle`.
- Plugins: `/api/dashboard/plugins/hub` plus install/enable/disable/update/remove.
- Cron: `/api/cron/jobs` plus pause/resume/trigger subroutes.
- Kanban: `/api/plugins/kanban/*` — boards, tasks, links, comments, run logs.
- Models: `/api/model/options`, `/api/model/auxiliary`, `/api/model/set`.
- Environment: `/api/env*` (`.env` CRUD + reveal).
- Logs: polled `/api/logs`.
- Updates: `/api/status`, `/api/hermes/update`, `/api/actions/hermes-update/status`.
- Profiles config editor: schema + current config via `/api/config/schema` and `/api/config`, non-destructive writes via `PUT /api/config`, and the profile list via `/api/profiles`. Soul and Personalities editors ride this surface (`/api/profiles/{profile}/soul` and `agent.personalities` in the config). Editing the default profile reuses the window's shared dashboard; editing a *named* profile launches an isolated profile-scoped dashboard (`hermes -p <name> dashboard`). An editable YAML mirror and the read-only two-profile comparison share the same surface.

The full per-route table lives in `docs/dashboard-api.md`; `docs/integration-coverage.md` tracks the integration boundary and capability gates.

A few operations remain on CLI fallbacks because Hermes does not expose dashboard routes for them yet:

- Sessions rename: `hermes sessions rename`.
- Tools enable/disable/list: `hermes tools ...`.
- Doctor report: `hermes doctor`.
- Gateway lifecycle writes: `hermes gateway start/stop/restart/install/uninstall`.

One more, update check/apply (`hermes update --check`, `hermes update`), uses the CLI *by choice* even though the dashboard routes above exist: only the CLI reports the commits-behind verdict for source installs, which `/api/status` does not.

Remote dashboard access on macOS is provided by spawning system `ssh` with a loopback `-L <local>:127.0.0.1:<remote>` forward and running `hermes dashboard` on the remote host. iOS reaches the dashboard over the pure-Swift NIO-SSH transport instead: one connection both execs `hermes dashboard` on the remote host and tunnels its HTTP over a `direct-tcpip` channel (no local forward), reusing the window's host-key trust so it doesn't re-prompt for a key the chat transport already trusted.

## Window Model

Each app window is scoped to one `ServerProfile`. The window owns its ACP session clients, dashboard client reference, CLI fallback runner, version cache, and capability table. `DashboardCoordinator` caches one dashboard supervisor per `(ServerProfile, Hermes profile)` pair: every window shares the default-profile dashboard, while the Profiles editor acquires a separate, profile-scoped supervisor (its own port + process) when editing a named profile, releasing it on profile switch or teardown.
