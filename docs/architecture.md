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

Live chat stays on ACP over newline-delimited JSON-RPC. Non-chat surfaces are backed by the Hermes dashboard HTTP API (`hermes dashboard --host 127.0.0.1 --port <ephemeral>`). Talaria never reads or writes Hermes SQLite files directly.

Each window acquires a dashboard endpoint for its `ServerProfile` through `DashboardSupervisor`. The supervisor starts `hermes dashboard`, polls `/api/status`, caches the session token scraped from the dashboard SPA, reference-counts consumers, and terminates the child when the last window releases it.

Dashboard-backed surfaces today:

- Sessions browse/search/read/delete: `/api/sessions`, `/api/sessions/search`, `/api/sessions/{id}`.
- Skills: `/api/skills`, `/api/skills/toggle`.
- Cron: `/api/cron/jobs` plus pause/resume/trigger subroutes.
- Logs: polled `/api/logs`.
- Updates: `/api/status`, `/api/hermes/update`, `/api/actions/hermes-update/status`.

Three operations remain on CLI fallbacks because Hermes does not expose dashboard routes for them yet:

- Sessions rename: `hermes sessions rename`.
- Tools enable/disable/list: `hermes tools ...`.
- Doctor report: `hermes doctor`.

Remote dashboard access on macOS is provided by spawning system `ssh` with a loopback `-L <local>:127.0.0.1:<remote>` forward and running `hermes dashboard` on the remote host. The pure-Swift NIO-SSH transport remains the iOS-capable ACP transport seam, but dashboard mode on iOS is deferred until NIO-based port forwarding lands.

## Window Model

Each app window is scoped to one `ServerProfile`. The window owns its ACP session clients, dashboard client reference, CLI fallback runner, version cache, and capability table. `DashboardCoordinator` shares one dashboard supervisor per profile across windows.
