# Hermes dashboard HTTP API

This documents the Hermes dashboard `/api/*` surface **as Talaria consumes it**. It is a
description of observed behavior, not a Hermes spec. Hermes (`hermes_cli/web_server.py`) is the
source of truth — when this doc and Hermes disagree, Hermes wins, and this doc is the thing that's
wrong. Everything here is verified against the `DashboardClient` call sites in
`HermesKit/Sources/HermesKit/Dashboard/DashboardClient.swift` and a live instance reporting Hermes
version `0.14.0` / release `2026.5.16`.

## How Talaria reaches it

Talaria spawns `hermes dashboard --host 127.0.0.1 --port <port>` (locally, or over SSH for remote
profiles) and talks to `http://127.0.0.1:<port>/api/*`. It **never** reads or writes Hermes SQLite
files directly — the dashboard API (plus a few CLI fallbacks) is the entire non-chat data path. See
`docs/architecture.md` for the process/supervisor model.

## Authentication

- The dashboard issues a per-process **session token**. Talaria obtains it by scraping the dashboard
  SPA (`GET /`) via `DashboardTokenExtractor`, then caches it (`DashboardSession`).
- Every request sends it as the header **`X-Hermes-Session-Token: <token>`** (see
  `DashboardClient.dispatch`, line ~1102). Requests with a JSON body also send
  `Content-Type: application/json`.
- A few routes are public (no token required) but Talaria sends the token anyway when it has one —
  e.g. `GET /api/config/schema`, `GET /api/status`.
- **`401` handling:** a `401` throws `DashboardClientError.unauthorized`, which triggers
  `onUnauthorized()` (re-scrape `GET /` for a fresh token) and **one** automatic retry. A second
  `401` propagates. This retry-once-on-401 wrapper is applied to every route via `sendDecoding` /
  `sendNoContent` / `sendRawData`.

## Error model

`check(response:data:)` (line ~1127) maps HTTP status to `DashboardClientError`:

| Status        | Result                                                              |
| ------------- | ------------------------------------------------------------------ |
| `200..<300`   | success                                                            |
| `401`         | `.unauthorized` → refresh token + retry once                       |
| any other     | `.http(statusCode:body:)` — `body` is the verbatim response text   |
| 2xx but body doesn't decode | `.decoding(String)` — wrong shape for the expected type |

### ⚠️ The SPA catch-all trap

Hermes serves an SPA with a **catch-all** route (`serve_spa`): **any unmatched path returns
`index.html` as HTML with HTTP `200`.** That means hitting a route that doesn't exist does **not**
give you a `404` — it gives you a `200` full of HTML, which sails through `check(...)` and then fails
in `JSONDecoder` as `DashboardClientError.decoding` ("…wasn't in the expected shape"). If a brand-new
route reliably throws `.decoding` with an HTML-looking body, suspect a **wrong/renamed path**, not a
schema mismatch. (This is exactly the bug that the Soul editor hit calling the non-existent
`/api/soul`; the real route is profile-scoped — see below.)

## Capability gates

Dashboard routes are gated by Hermes version in `HermesKit/Sources/HermesKit/Hermes/Capabilities.swift`.
Below the gate, the affected surface shows a "dashboard required" banner rather than erroring. These
are **UI banners, not hard load gates** — an older-Hermes profile still connects; its dashboard
surfaces just stay offline.

| Capability          | Min Hermes version | Covers                                   |
| ------------------- | ------------------ | ---------------------------------------- |
| `requiresDashboard` | `0.14.0`           | the dashboard itself (`web_server.py`)   |
| `requiresModelAPI`  | `0.14.0`           | `/api/model/*`                           |
| `requiresEnvAPI`    | `0.14.0`           | `/api/env*`                              |
| `requiresMCPAPI`    | `0.15.1`           | `/api/mcp/*` (added after the base dashboard) |

## Routes Talaria calls

Profile-scoped routes embed `{profile}` (the Hermes profile name, default `"default"`). Request
bodies are JSON; the "Body" column lists the wrapping the dashboard's Pydantic models expect.

### Status & updates

| Method | Path                                  | Body | Returns / notes |
| ------ | ------------------------------------- | ---- | --------------- |
| GET    | `/api/status`                         | —    | `DashboardStatus`; also the supervisor's readiness probe. |
| GET    | `/api/actions/hermes-update/status`   | —    | `DashboardActionStatus` (in-progress update state). |
| POST   | `/api/hermes/update`                  | —    | Starts a Hermes self-update. |

### Sessions

| Method | Path                              | Body | Returns / notes |
| ------ | --------------------------------- | ---- | --------------- |
| GET    | `/api/sessions`                   | —    | `DashboardSessionsResponse`. Query: `limit`, `offset`. |
| GET    | `/api/sessions/search`            | —    | `DashboardSessionsSearchResponse`. Query: `q` (required), `limit`. |
| GET    | `/api/sessions/{id}`              | —    | `DashboardSessionDetail`. |
| GET    | `/api/sessions/{id}/messages`     | —    | `DashboardSessionMessagesResponse`. |
| DELETE | `/api/sessions/{id}`              | —    | Deletes a session. |

> Session **rename** has no dashboard route — Talaria falls back to `hermes sessions rename` (CLI).

> `DashboardSessionSummary` decodes the high-value per-session fields the browser
> surfaces — `model`, `message_count`, `tool_call_count`, `last_active`,
> `is_active`, `preview`, token counts, and cost (`estimated_cost_usd` /
> `actual_cost_usd` / `cost_status`) — plus `total` on the response (server-wide
> session count). All optional, so older servers that omit them still decode.
> The leaner `/api/sessions/search` shape carries none of these.

### Skills

| Method | Path                  | Body                          | Returns / notes |
| ------ | --------------------- | ----------------------------- | --------------- |
| GET    | `/api/skills`         | —                             | `[DashboardSkill]`. |
| PUT    | `/api/skills/toggle`  | `{name, enabled}`             | Enable/disable a skill. |

> The Skills Hub has **no dashboard routes**. **Search** reads the public Nous
> index over plain HTTP (`https://hermes-agent.nousresearch.com/docs/api/skills-index.json`,
> no auth, cached client-side via `SkillsHubCatalog`). **Install / update /
> uninstall** are inherently local (quarantine + `skills_guard` scan + write to
> `~/.hermes/skills/`) and run via the CLI fallback `hermes skills …`.

### Cron

| Method | Path                            | Body                                    | Returns / notes |
| ------ | ------------------------------- | --------------------------------------- | --------------- |
| GET    | `/api/cron/jobs`                | —                                       | `[DashboardCronJob]`. |
| POST   | `/api/cron/jobs`                | `{prompt, schedule, name?, deliver?}`   | Returns the created `DashboardCronJob`. |
| PUT    | `/api/cron/jobs/{id}`           | `{updates: {<field>: <string>}}`        | Free-form patch (`CronJobUpdate` wraps an `updates` dict). |
| DELETE | `/api/cron/jobs/{id}`           | —                                       | Deletes a job. |
| POST   | `/api/cron/jobs/{id}/pause`     | —                                       | Pause. |
| POST   | `/api/cron/jobs/{id}/resume`    | —                                       | Resume. |
| POST   | `/api/cron/jobs/{id}/trigger`   | —                                       | Run now. |

### Profiles

| Method | Path                     | Body                                         | Returns / notes |
| ------ | ------------------------ | -------------------------------------------- | --------------- |
| GET    | `/api/profiles`          | —                                            | `{profiles: [DashboardProfile]}`. Profile-agnostic (scans the profiles dir). |
| POST   | `/api/profiles`          | `{name, clone_from_default, no_skills}`      | Creates by cloning **default only**; arbitrary-source clone needs the CLI. |
| PATCH  | `/api/profiles/{name}`   | `{new_name}`                                 | Rename in place. `default` is rejected by the server. |
| DELETE | `/api/profiles/{name}`   | —                                            | Delete. Server forces `yes=True`; `default` is rejected. |

### Soul (profile-scoped)

| Method | Path                              | Body         | Returns / notes |
| ------ | --------------------------------- | ------------ | --------------- |
| GET    | `/api/profiles/{profile}/soul`    | —            | `{content: <string>, exists: <bool>}`. |
| PUT    | `/api/profiles/{profile}/soul`    | `{content}`  | Writes `SOUL.md`. Returns `{ok: true}`. |

> There is **no** top-level `/api/soul`. It must be profile-scoped or you hit the SPA catch-all trap
> above.

### Memory (read-only status)

| Method | Path           | Body | Returns / notes |
| ------ | -------------- | ---- | --------------- |
| GET    | `/api/memory`  | —    | `{active: <string>, providers: [{name, description, configured}], builtin_files: {memory: <int>, user: <int>}}`. `active = ""` means the **built-in** file-backed memory; `builtin_files` are byte sizes only. |

> There is **no** dashboard route for the raw text of `MEMORY.md` / `USER.md`. The agent edits that
> content via its internal `memory` tool. The Memory editor therefore reads **and writes** those files
> directly on disk (the one direct-write exception — see `docs/security.md` and `docs/integration-coverage.md`),
> using `GET /api/memory` only for the read-only provider line and the "external provider active" warning.
> The provider **picker** lives in the Plugins screen via `PUT /api/memory/provider`; `POST /api/memory/reset`
> is out of scope.

### Models (gated on `requiresModelAPI` ≥ `0.14.0`)

| Method | Path                    | Body                                 | Returns / notes |
| ------ | ----------------------- | ------------------------------------ | --------------- |
| GET    | `/api/model/options`    | —                                    | `DashboardModelOptions`. Authenticated providers only; Talaria overlays a static catalog to show the rest disabled. |
| GET    | `/api/model/auxiliary`  | —                                    | `DashboardModelAssignments`. Unset slots read as `provider:"auto"`. |
| POST   | `/api/model/set`        | `{scope, task?, provider, model}`    | `scope` = `main`/`auxiliary`. For `main`, `task` is **omitted**. For `auxiliary`: a slot name targets one task, `""` = all slots, `"__reset__"` = reset all to auto. |

### Usage analytics (gated on `requiresDashboard` ≥ `0.14.0`)

Read-only token/cost/session analytics, backing the **Usage** screen. Both ship
in the same `0.14.0` `web_server.py` as the dashboard itself, so they share the
`requiresDashboard` gate — there is no separate analytics capability constant.
Every token/cost/count field is built from SQL `SUM`/`COUNT` aggregates, so on an
empty-history server (or a `days` window with no sessions) the `SUM` fields are
`null` while `COUNT` and `COALESCE(...,0)` cost fields are `0`. Talaria decodes
every numeric field as optional and coalesces to `0`.

| Method | Path                    | Body | Returns / notes |
| ------ | ----------------------- | ---- | --------------- |
| GET    | `/api/analytics/usage`  | —    | `DashboardUsageAnalytics`. Query `days` (default `30`). `{daily: [{day, input_tokens, output_tokens, cache_read_tokens, reasoning_tokens, estimated_cost, actual_cost, sessions, api_calls}], by_model: [{model, input_tokens, output_tokens, estimated_cost, sessions, api_calls}], totals: {total_input, total_output, total_cache_read, total_reasoning, total_estimated_cost, total_actual_cost, total_sessions, total_api_calls}, period_days, skills}`. `skills` (insights summary + top skills) is returned but not decoded. |
| GET    | `/api/analytics/models` | —    | `DashboardModelAnalytics`. Query `days` (default `30`). Richer per-model rows than `usage`'s `by_model`: `{models: [{model, provider, input_tokens, output_tokens, cache_read_tokens, reasoning_tokens, estimated_cost, actual_cost, sessions, api_calls, tool_calls, last_used_at, avg_tokens_per_session, capabilities: {supports_tools, supports_vision, supports_reasoning, context_window, max_output_tokens, model_family}}], totals: {distinct_models, …}, period_days}`. Optional enrichment for a future Models tab. |

### Config

| Method | Path                  | Body              | Returns / notes |
| ------ | --------------------- | ----------------- | --------------- |
| GET    | `/api/config/schema`  | —                 | Field schema for the structured editor. **Public** route. Parsed via Yams (order-preserving), not `JSONDecoder`. |
| GET    | `/api/config`         | —                 | Current config of the **dashboard process's profile**, verbatim `JSONValue` (arbitrary keys round-trip). |
| PUT    | `/api/config`         | `{config: {...}}` | Whole-config atomic write (`ConfigUpdate` wraps under `config`). |

> Config is scoped to whichever profile the dashboard process was launched with — editing a *named*
> profile spins up a separate `hermes -p <name> dashboard`. Soul is the explicit per-call exception
> (it takes `{profile}` in the path), so it works through the shared default dashboard.

### Logs

| Method | Path          | Body | Returns / notes |
| ------ | ------------- | ---- | --------------- |
| GET    | `/api/logs`   | —    | `DashboardLogsResponse`. Query: `file`, `lines`, `level`, `component`, `search` (all optional). Polled. |

### Plugins

| Method | Path                                            | Body                                  | Returns / notes |
| ------ | ----------------------------------------------- | ------------------------------------- | --------------- |
| GET    | `/api/dashboard/plugins/hub`                    | —                                     | `DashboardPluginsHub` (installed plugins + memory/context provider selections). |
| POST   | `/api/dashboard/agent-plugins/install`          | `{identifier, force, enable}`         | Install from `owner/repo` or a Git URL. Returns a leniently-parsed install summary. |
| POST   | `/api/dashboard/agent-plugins/{name}/enable`    | —                                     | Enable. `{name}` may contain `/` (e.g. `browser/browser_use`). |
| POST   | `/api/dashboard/agent-plugins/{name}/disable`   | —                                     | Disable. |
| POST   | `/api/dashboard/agent-plugins/{name}/update`    | —                                     | `git pull` for a git-sourced plugin. |
| DELETE | `/api/dashboard/agent-plugins/{name}`           | —                                     | Remove a user-installed plugin. |
| PUT    | `/api/dashboard/plugin-providers`               | `{memory_provider?, context_engine?}` | Writes `memory.provider` / `context.engine` to `config.yaml` (next-session). |

### Kanban (Hermes kanban plugin)

Every route is mounted under `/api/plugins/kanban` — the prefix the dashboard
applies to the bundled kanban plugin's router (`app.include_router(router,
prefix=…)`). It rides the same `requiresDashboard` gate as the rest of the
dashboard; there is no separate capability for it. The surface is large enough
that its `DashboardClient` methods live in `DashboardClient+Kanban.swift`.

| Method | Path                                            | Body | Returns / notes |
| ------ | ----------------------------------------------- | ---- | --------------- |
| GET    | `/api/plugins/kanban/board`                     | —    | `KanbanBoard` (column layout). Query: `board` (omit = current), `include_archived`, `tenant`. |
| GET    | `/api/plugins/kanban/tasks/{id}`                | —    | `KanbanTaskDetail`. |
| POST   | `/api/plugins/kanban/tasks`                     | `{title, body?, assignee?, tenant?, priority, workspace_kind, parents[], triage, skills?}` | Create a task. |
| PATCH  | `/api/plugins/kanban/tasks/{id}`                | partial task fields | Update a task (move column, reassign, edit). |
| DELETE | `/api/plugins/kanban/tasks/{id}`                | —    | Delete a task. |
| POST   | `/api/plugins/kanban/tasks/bulk`                | bulk op payload | Bulk move/update across tasks. |
| POST   | `/api/plugins/kanban/tasks/{id}/comments`       | `{body, author?}` | Add a comment. |
| GET    | `/api/plugins/kanban/tasks/{id}/log`            | —    | Run/agent log for a task. Query: `tail`. |
| POST   | `/api/plugins/kanban/links`                     | `{parent_id, child_id}` | Link a parent/child task. |
| DELETE | `/api/plugins/kanban/links`                     | —    | Unlink. Query: `parent_id`, `child_id`. |
| GET    | `/api/plugins/kanban/boards`                    | —    | `KanbanBoardsResponse`. Query: `include_archived`. |
| POST   | `/api/plugins/kanban/boards`                    | board create payload | Create a board. |
| PATCH  | `/api/plugins/kanban/boards/{slug}`             | board patch | Rename/edit a board. |
| DELETE | `/api/plugins/kanban/boards/{slug}`             | —    | Delete a board. |
| POST   | `/api/plugins/kanban/boards/{slug}/switch`      | —    | Make `{slug}` the current board. |
| GET    | `/api/plugins/kanban/diagnostics`               | —    | `[KanbanDiagnostic]`. Query: `severity`. |
| GET    | `/api/plugins/kanban/runs/{id}`                 | —    | Raw run record (`JSONValue`). |
| GET    | `/api/plugins/kanban/stats`                     | —    | Board stats (`JSONValue`). |
| GET    | `/api/plugins/kanban/assignees`                 | —    | `[String]` of known assignees. |

### Environment (gated on `requiresEnvAPI` ≥ `0.14.0`)

| Method | Path                | Body              | Returns / notes |
| ------ | ------------------- | ----------------- | --------------- |
| GET    | `/api/env`          | —                 | Dict keyed by var name → `{is_set, redacted_value, description, url, category, is_password, tools, advanced}`. **Dict order is not preserved**; Talaria sorts by `(category-rank, name)`. |
| PUT    | `/api/env`          | `{key, value}`    | Set/update a known var. Server `is_managed()` rejections surface as `.http`. |
| DELETE | `/api/env`          | `{key}`           | Remove from `.env` (JSON body). Missing key → `404`. |
| POST   | `/api/env/reveal`   | `{key}`           | Returns `{key, value}` (unredacted). **Rate-limited 5 / 30s** → excess = `429`; unset key = `404`. |

### MCP servers (gated on `requiresMCPAPI` ≥ `0.15.1`)

Added *after* the base 0.14.0 dashboard (the "full administration panel" change, Hermes #36704),
so this family carries a later pin than the rest of the dashboard. Wraps the same config layer as
`hermes mcp`, so servers added here also show under `hermes mcp list`. stdio `env` values are
**redacted** on read; `transport` is derived server-side (`http` if a `url`, `stdio` if a `command`,
else `unknown`). The `DashboardClient` methods live in `DashboardClient+MCP.swift`.

| Method | Path                              | Body                                      | Returns / notes |
| ------ | -------------------------------- | ----------------------------------------- | --------------- |
| GET    | `/api/mcp/servers`               | —                                         | `{servers: [DashboardMCPServer]}`. env redacted; `tools` is an allowlist of names or `null` = all (not a count). |
| POST   | `/api/mcp/servers`               | `{name, url?, command?, args[], env{}, auth?}` | Add. Echoes the created server. No transport field — url ⇒ remote, command ⇒ stdio. `409` if the name exists; `400` if neither url nor command. `auth` = `oauth`/`header`. |
| POST   | `/api/mcp/servers/{name}/test`   | —                                         | `{ok, tools: [{name, description}], error?}`. A reachable-but-failing probe still returns `200` with `ok:false`+`error`; unknown server = `404`. |
| PUT    | `/api/mcp/servers/{name}/enabled`| `{enabled}`                               | Toggle. Returns `{ok, name, enabled}`. Disabled servers stay in config. |
| DELETE | `/api/mcp/servers/{name}`        | —                                         | Remove. `404` if unknown. |
| GET    | `/api/mcp/catalog`               | —                                         | `{entries: […], diagnostics: […]}`. Entry: `{name, description, source, transport, auth_type, required_env: [{name, prompt, required}], needs_install, installed, enabled}`. |
| POST   | `/api/mcp/catalog/install`       | `{name, env{}, enable}`                   | Install a catalog entry. `{ok, name, background, action?}`; `background:true` for git-bootstrap entries (run as the `mcp-install` background action). |

> There is **no** in-place edit route and **no** route to set a server's tool allowlist — the native
> "Edit" is delete + re-add, which can't restore a `tools` allowlist (the editor warns when one exists).

## CLI fallbacks (no dashboard route)

Several operations still shell out to `hermes` because the dashboard exposes no route for them:

- **Sessions rename** — `hermes sessions rename`.
- **Tools enable/disable/list** — `hermes tools ...`. (The dashboard has `GET /api/tools/toolsets`
  for listing but no toggle route, so the whole flow stays on the CLI.)
- **Skills Hub install/update/uninstall + installed/check reads** —
  `hermes skills install/update/uninstall/list/check`. No dashboard route exists,
  and these are inherently local (security scan + filesystem writes). Uninstall
  has no `--yes` in v0.14.0, so Talaria feeds `y\n` on stdin; remote uninstall is
  deferred (the SSH runners drop stdin). Search is **not** a fallback — it uses
  the public Nous index over HTTP (`SkillsHubCatalog`).
- **Doctor report** — `hermes doctor`.
- **Gateway lifecycle** — `hermes gateway start/stop/restart/install/uninstall`.

One more, **update check/apply** (`hermes update --check` / `hermes update`), uses the CLI *by
choice* even though `POST /api/hermes/update` exists: only the CLI reports the commits-behind verdict
for source installs. See `docs/integration-coverage.md` for the full enumerated fallback list.

## Maintaining this doc

This file tracks the `DashboardClient` call sites. When you add, remove, or change a route there (or
in Hermes' `web_server.py`), update the matching row. The route paths and body shapes above are the
contract Talaria depends on; the SPA catch-all trap means a silently-wrong path fails as a decode
error, not a 404, so getting the path exactly right matters.
