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

Sprint 3 adds `session/load` on `HermesClient`, a `SessionManager` that multiplexes multiple sessions per window, and a read-only `HermesDB` that browses `~/.hermes/state.db` (FTS5 with a `LIKE` fallback). Rename and delete go through the `hermes` CLI via `HermesAdmin`. `session/list` is **not** wired — we read the on-disk database directly for now; a remote `session/list` path will be considered for the SSH snapshot pipeline.

## Sprint 4 — Remote SSH

`SSHTransport` now exposes a non-interactive `probeConnectivity(profile:)` helper plus a typed `SSHTransportError` (auth failed, host key mismatch, timeout, unreachable, other). The classifier is reused both by the editor's probe button and by the long-lived ACP transport when it exits unexpectedly.

`HermesProbe` runs `command -v hermes; hermes --version` over either a local shell or SSH and records `HermesProbeResult { binaryPath, version, versionRaw, acpSupported }`. Profiles are persisted via `ProfileStore` (Codable JSON at `~/Library/Application Support/Talaria/profiles.json`). SSH identity files are referenced by path — secrets stay in the user's `~/.ssh`, not in Talaria storage.

Server windows are now keyed by `ServerProfile.id` via `WindowGroup(for: UUID.self)`. The bundled local Hermes lives at a well-known UUID (`ProfileDirectory.localProfileID`) so it's always available without persisting it on disk. Menus expose **New Server Window** and **Recent Servers**.

Remote browsing uses a `RemoteSnapshot` actor keyed by profile ID. Refreshes run `ssh <host> sqlite3 <hermesHome>/state.db .backup /tmp/talaria-<uuid>.db`, fetch via `sftp -b -`, then clean up the temp file. The cached snapshot is opened read-only by `HermesDB` at `~/Library/Caches/Talaria/<server-id>/state.db`. The sidebar shows an age badge with a refresh button; snapshots invalidate on admin writes (rename/delete) and on mutating ACP notifications (`tool_call_update` with `kind ∈ {edit, delete, move}` and status `completed`, plus `session_info_update`).

## Sprint 5 — Management surfaces

The six `Talaria/Manage/*View.swift` placeholders are now backed by a real `HermesAdmin` runner. Block A added an `AdminEvent` stream variant — `runStream(_:) -> AsyncThrowingStream<AdminEvent, Error>` — alongside the existing one-shot `run(_:)`. `LocalHermesAdminRunner` and `RemoteHermesAdminRunner` both override `runStream` with a line-buffered `AdminLineReader` over their stdout/stderr pipes; cancellation of the stream terminates the spawned child.

- **Skills / Tools** (`HermesSkills`, `HermesTools`): tolerant list parsers (checkbox `[x] name path` and table `name enabled path` forms), with `enable` / `disable` mutations and a markdown-rendered `show` preview pane for skills.
- **Cron** (`HermesCron`): list / add / update / delete / pause / resume / runNow over `hermes cron …` subcommands, with a typed `HermesCronError.commandUnavailable` that the view turns into a banner instead of looking permanently broken. No `jobs.json` fallback in Sprint 5 — gated with an upstream FR if mutating subcommands are missing.
- **Logs** (`HermesLogs`, `LocalLogTailing`, `RemoteLogTailing`): live tail with a tolerant `[ISO] [LEVEL] component: message` parser plus unstructured-line fallback. Local tailer polls `<hermesHome>/logs/*.log` for appended bytes (handles rotation); remote tailer spawns `ssh … tail -F` directly and reuses `AdminLineReader`. The view ring-buffers at 5,000 lines, filters by level + component, supports pause/resume and "Copy visible".
- **Doctor** (`HermesDoctor`): one-shot `hermes doctor`, with a section splitter that recognises `== Title ==`, `--- Title ---`, and ALL-CAPS standalone headers. "Copy diagnostic bundle" puts the raw report + Talaria version + profile summary on the clipboard.
- **Updates** (`HermesUpdates`): `update --check` parser tolerates `current X, latest Y`, `Up to date (X)`, `Update available: X → Y`, and `X -> Y`. "Install update" streams `update` apply via `runStream` into a scrolling log view with exit-code summary.
- **Capability gating**: `CapabilityTable.has(_:in:)` reads more fluently at view call sites. Sprint 5 surfaces feature absence as a banner rather than a crash.

## Sprint 6 — Capability minimums

Sprint 6 added `skillsToggle` and `toolsEnablePerPlatform` to `HermesCapability` and replaced the `0.0.0` placeholders with pins resolved from the Hermes git history:

| Capability | Min Hermes | First tag |
| --- | --- | --- |
| `acp` / `permissions` / `diffs` | `0.3.0` | `v2026.3.17` |
| `cronCRUD` | `0.3.0` | `v2026.3.17` |
| `skillsToggle` | `0.2.0` | `v2026.3.12` |
| `toolsEnablePerPlatform` | `0.4.0` | `v2026.3.23` |
| `updateCheck` | `0.12.0` | `v2026.4.30` |

Sprint 6 also wired `capabilityBanner(.<cap>, feature:, version:)` (defined in `Talaria/Manage/ManageHarness.swift`) into `CronView`, `ToolsView`, and `UpdatesView`. Each surface checks `CapabilityTable.has(_:in:)` against the profile's probed Hermes version and renders an orange warning banner when the pin isn't met; hard runtime errors still take precedence as red banners. `SkillsView` is intentionally skipped because Talaria 1.0 renders skills read-only.

## Sprint 7 — Mandatory dashboard

Sprint 7 makes the Hermes dashboard HTTP API (`hermes dashboard`, FastAPI/Uvicorn on `127.0.0.1:<ephemeral>`) a hard prerequisite for every non-chat surface. The SQLite snapshot path, the Rich-output scrapers for Skills / Cron / Logs / Updates, and the per-route capability flags they gated were removed:

- Deleted `HermesDB.swift`, `RemoteSnapshot.swift`, `RemoteSnapshotTransfer.swift`, `HermesSkills.swift`, `HermesCron.swift`, `HermesLogs.swift`, `HermesUpdates.swift` (and their tests / fixtures).
- Collapsed `cronCRUD` / `updateCheck` / `skillsToggle` and the five per-route `dashboard*API` flags into a single `requiresDashboard` capability pinned at Hermes 0.14.0.
- Added `DashboardClient` (URLSession, retry-on-401), `DashboardSession` (token cache scraped from `GET /`), `DashboardSpawnSpec` (local + remote-via-ssh-`-L`), `DashboardSupervisor` (refcounted spawn + reachability poll + missing-`[web]` detection), `SystemDashboardProcessLauncher`, `DashboardPortAllocator`, and `DashboardUpdatesService`.
- `DashboardCoordinator` in `Talaria/Windows/ServerWindow.swift` owns one supervisor per profile, shared across windows.
- `DoctorView` shows two prereq probes — `Hermes ≥ 0.14.0` and "Dashboard reachable" — alongside the CLI-driven `hermes doctor` report.

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
| Tools enable/disable | _no toggle route — still on `hermes tools enable/disable` CLI_ |
| Doctor | _no `/api/doctor` — still on `hermes doctor` CLI_ |
| Chat | _stays on ACP/JSON-RPC, not the dashboard_ |

iOS dashboard mode is deferred until NIO-SSH port forwarding lands; today the iOS surface only exercises ACP chat.
