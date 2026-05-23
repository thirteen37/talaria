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
