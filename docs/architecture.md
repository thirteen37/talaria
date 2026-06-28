# Architecture

Talaria is a native SwiftUI front-end for Hermes (macOS and iOS app targets) backed by a shared `HermesKit` Swift package. The app renders Hermes natively instead of embedding the TUI. Live chat speaks **JSON-RPC 2.0 over a WebSocket** to the dashboard's `/api/ws` gateway — the same path Hermes Desktop uses — riding the same `hermes dashboard` the non-chat surfaces use.

## Core Packages

- `ACP`: Codable JSON-RPC plus the shared chat-event model (`HermesNotification`, `SessionUpdate`, `ToolCall`, …) the chat UI consumes. Named for the original ACP protocol; the gateway client maps gateway events onto these types.
- `Transport`: shared pure-Swift NIO-SSH primitives (connection factory, credential providers, host-key trust/TOFU, `OneShotProcess`) used by the dashboard connection and command runners; also the pure launch-spec/command builder for `hermes chat --tui` terminal sessions (`TUILaunchSpec.swift`). No longer a chat transport — the chat WebSocket lives in `Dashboard`.
- `Client`: `SessionManager` (per-session lifecycle + notification fan-out/replay) and the `ChatBackend` seam; live chat uses `GatewayChatClient`.
- `Dashboard`: HTTP client, token/session handling, dashboard process supervision, spawn specs, update polling, and the chat WebSocket (`GatewayWebSocket` + `URLSessionGatewayWebSocket` / `NIOSSHGatewayWebSocket`).
- `Hermes`: CLI fallbacks, version parsing, doctor/tool parsers, and capability gates.
- `Profiles`: local and SSH server profiles.

## Read And Write Model

Live chat speaks JSON-RPC 2.0 over a WebSocket to the dashboard's `/api/ws` gateway (`GatewayChatClient`), riding the same `hermes dashboard` as the non-chat surfaces. Non-chat surfaces are backed by the Hermes dashboard HTTP API (`hermes dashboard --host 127.0.0.1 --port <port>`). Talaria allocates an ephemeral loopback port by default, but profiles can pin a dashboard port when the automatic choice conflicts with local or remote host policy. Talaria never reads or writes Hermes SQLite files directly.

Each window acquires a dashboard endpoint for its `ServerProfile` through `DashboardSupervisor`. The supervisor starts `hermes dashboard`, polls `/api/status`, caches the session token scraped from the dashboard SPA, reference-counts consumers, and terminates the child when the last window releases it.

A live dashboard can wedge without the refcount knowing — a dropped `ssh -L` forward, a transient network failure, or a crashed/restarted remote — leaving the client non-nil but every call failing. `DashboardSupervisor.forceShutdown()` tears the child down unconditionally (ignoring the refcount); the macOS coordinator's `forceRelease` also evicts the supervisor from its cache. The window's `reconnectDashboard()` routes through `performRecovery()`, which chains a force-shutdown into a fresh acquire and then re-resumes any open live chat tabs over the rebuilt tunnel (`SessionsStore.recoverLiveSessions()`), so a single user action ("Reconnect", available in the sidebar/banner and the window toolbar) rebuilds a genuinely new process and client from any state *and* keeps the open chats alive rather than leaving them dead. The same `performRecovery()` backs the iOS/iPad background→foreground auto-reconnect (gated behind a liveness probe — see `docs/security.md`); both share an `isRecovering` guard so they never double-spawn. Windows sharing the profile recover on their own next acquire/reconnect.

Reachability is build-aware. The first `hermes dashboard` after a Hermes update compiles the web UI before it starts listening — over an `ssh -L` forward this routinely outlasts the base window — so the supervisor watches the spawned process's output: once it sees `Building web UI…` it extends the reachability deadline from the base timeout (20s) to a build cap (180s) and fires a callback the window surfaces as a "Building web UI…" banner. If the dashboard still never answers, the thrown `notReachable` carries the last probe error (e.g. `URLError -1005`, or ssh's `channel … connect failed: Connection refused`), and the full probe/stderr/spawn-command detail is logged under the `com.talaria.hermeskit` `dashboard` os_log category (visible in macOS Console.app — see [viewing-logs.md](viewing-logs.md)) — so a "didn't come online" failure says *why* rather than timing out silently.

The full route table Talaria depends on — auth header, error model, the SPA catch-all trap, and per-route bodies/shapes — is documented in `docs/dashboard-api.md`.

Dashboard-backed surfaces today:

- Sessions browse/search/read/delete: `/api/sessions`, `/api/sessions/search`, `/api/sessions/{id}`.
- Skills list/toggle: `/api/skills`, `/api/skills/toggle`. The Skills Hub has no dashboard routes — **search** reads the public Nous index over HTTP (`SkillsHubCatalog`), and **install/update/uninstall** use the CLI fallback (below).
- Plugins: `/api/dashboard/plugins/hub` plus install/enable/disable/update/remove.
- MCP servers: `/api/mcp/*` — registry CRUD + connection test + Nous catalog browse/install (gated on `requiresMCPAPI` ≥ `0.15.1`, added after the base dashboard).
- Cron: `/api/cron/jobs` plus pause/resume/trigger subroutes.
- Kanban: `/api/plugins/kanban/*` — boards, tasks, links, comments, run logs.
- Models: `/api/model/options`, `/api/model/auxiliary`, `/api/model/set`.
- Environment: `/api/env*` (`.env` CRUD + reveal). Custom-var enumeration also reads the `.env` file directly (see below).
- Memory: `GET /api/memory` for read-only provider status only. The built-in `MEMORY.md` / `USER.md` text has no dashboard route, so the Memory editor reads **and writes** those files directly on disk.
- Logs: polled `/api/logs`.
- Updates: `/api/status`, `/api/hermes/update`, `/api/actions/hermes-update/status`.
- Profiles config editor: schema + current config via `/api/config/schema` and `/api/config`, non-destructive writes via `PUT /api/config`, and the profile list via `/api/profiles`. Soul and Personalities editors ride this surface (`/api/profiles/{profile}/soul` and `agent.personalities` in the config). All profiles — the window's own and the comparison's target — are reached through the **window's shared dashboard client scoped via `?profile=<name>`** (`DashboardClient.scoped(toProfile:)`); the single dashboard serves every profile, so no separate per-profile dashboard is spawned. An editable YAML mirror and the read-only two-profile comparison share the same surface.

The full per-route table lives in `docs/dashboard-api.md`; `docs/integration-coverage.md` tracks the integration boundary and capability gates.

A few operations remain on CLI fallbacks because Hermes does not expose dashboard routes for them yet:

- Sessions rename: `hermes sessions rename`.
- Tools enable/disable/list: `hermes tools ...`.
- Skills: Hub install/update/uninstall, the lifecycle commands `audit`/`reset`/`repair-official`/`opt-in`/`opt-out`/`publish`, and `skills list`/`check` reads: `hermes skills ...`. Install/update/audit/reset/repair/opt-in/opt-out/publish run non-interactively (and over remote runners); clean `uninstall` lacks `--yes`, so Talaria confirms via stdin (`y\n`), which only the local runner delivers — clean uninstall is local-only, while **Force remove** removes any skill's directory directly (local `FileManager` / remote `rm -rf` over the host shell). The Skills detail panel also reads `SKILL.md` directly for its source preview, and the Skills screen reads `skills/.bundled_manifest` directly (local / remote SSH) to surface tracked built-ins whose files are absent from the active tree (deleted or archived under `.archive/`; absence detected via a host-shell `find`+`grep` presence scan, not dashboard-list membership), each restorable via `skills reset`. See `docs/security.md`.
- Doctor report: `hermes doctor`.
- Gateway lifecycle writes: `hermes gateway start/stop/restart/install/uninstall`.

One more, update check/apply (`hermes update --check`, `hermes update`), uses the CLI *by choice* even though the dashboard routes above exist: only the CLI reports the commits-behind verdict for source installs, which `/api/status` does not.

All non-dashboard file access — the `.env` custom-var read and the Memory editor's `MEMORY.md` / `USER.md` read+write — routes through one unified `HermesFileStore` (`HermesKit/.../Hermes/`). It resolves the local URL or remote home-relative path and dispatches local `FileManager` vs. the SSH `RemoteSnapshotTransfer` (NIO `cat`, or system-`sftp` on macOS), now extended with a temp-then-atomic-rename `upload` for the direct-write case. `HermesSoulReader`, `HermesConfigReader`, and `HermesEnvFileReader` are thin wrappers over it; `HermesMemoryStore` is the memory-specific one. Remote writes reuse the read path's SSH auth and host-key trust, adding no new trust surface.

Remote dashboard access on macOS is provided by spawning system `ssh` with a loopback `-L <local>:127.0.0.1:<remote>` forward and running `hermes dashboard` on the remote host. iOS reaches the dashboard over the pure-Swift NIO-SSH transport instead: one connection both execs `hermes dashboard` on the remote host and tunnels its HTTP — and the live-chat WebSocket — over `direct-tcpip` channels (no local forward), reusing the window's host-key trust so it doesn't re-prompt for a key the dashboard connection already trusted.

## Terminal (TUI) Sessions (macOS)

Alongside the native gateway chat, a chat can be opened as the real Hermes TUI — the full terminal experience Hermes ships — rendered inline in the detail pane by an embedded terminal emulator (SwiftTerm). It is a per-launch choice: a "New TUI session" button beside "New session", and an "Open as TUI" item on a row in the sessions browser (which resumes that session). There is no global default or setting.

A TUI tab bypasses both the gateway chat path *and* the dashboard. Talaria spawns `hermes chat --tui` directly in a PTY (resume adds `-r <id>`; the `-p <name>` profile flag precedes the subcommand) and renders its raw terminal output:

- **Local** profiles run `env hermes [-p <name>] chat --tui` with the login-shell PATH and `HERMES_HOME` (the same env story as the local dashboard launch), and the session cwd as the process working directory.
- **Remote** profiles always use system `ssh -tt` (a local PTY process the terminal can drive), even when the macOS NIO-SSH opt-in is enabled — the NIO path cannot feed a local-process terminal view. The remote command runs over `ssh -tt` like the remote dashboard launch, but invokes `chat --tui` rather than `dashboard`.

The launch command is assembled in `HermesKit` (`Transport/TUILaunchSpec.swift`, pure and unit-tested for exact command shape). The SwiftTerm view, the per-process lifetime, and a process-wide registry that keeps a terminal alive across tab switches (and reaps it on tab close and window teardown) live in a macOS-only app seam (`Chat/macOS/HermesTerminalView.swift`). SwiftTerm is a dependency of the macOS app target only — not the iOS target and not `HermesKit`, which stays UI-free. iOS has no local-process / PTY path, so TUI tabs cannot be created there; the shared code compiles via a seam stub.

Only one mode runs per session id at a time: opening a session as a TUI is disabled while it is open inline (gateway chat), and opening a session inline focuses an existing TUI tab instead of starting a second `hermes` resuming the same session.

## Window Model

Each app window is scoped to one `ServerProfile`. The window owns its chat session clients (over the dashboard gateway), dashboard client reference, CLI fallback runner, version cache, and capability table. `DashboardCoordinator` caches one dashboard supervisor per `(ServerProfile, Hermes profile)` pair: every window shares the default-profile dashboard, while the Profiles editor acquires a separate, profile-scoped supervisor (its own port + process) when editing a named profile, releasing it on profile switch or teardown.
