# Hermes `/api/ws` gateway chat protocol

This freezes the **JSON-RPC-2.0-over-WebSocket** protocol that Hermes Desktop (the first-party
Electron app) uses to drive live chat through the dashboard gateway, so Talaria can migrate live
chat onto the same `/api/ws` endpoint and eventually retire its second backend (`hermes acp`) and the
bespoke ACP transport stack.

It is a description of **observed behavior**, not a Hermes spec. Hermes is the source of truth — when
this doc and Hermes disagree, Hermes wins and this doc is wrong. Everything here is verified against
Hermes at `~/.hermes/hermes-agent` (version `0.15.1` / release `2026.5.29`):

- Server route + auth: `hermes_cli/web_server.py` (`@app.websocket("/api/ws")`, line ~8102).
- Server JSON-RPC dispatch + event emit: `tui_gateway/server.py` (`@method(...)` handlers, `_emit`).
- Client envelope + correlation: `apps/shared/src/json-rpc-gateway.ts` (`JsonRpcGatewayClient`).
- Client event→UI mapping: `apps/desktop/src/app/session/hooks/use-message-stream.ts`
  (`handleGatewayEvent`), `apps/desktop/src/app/session/hooks/use-prompt-actions.ts`,
  `apps/desktop/src/app/session/hooks/use-session-actions.ts`, and the overlay components
  (`tool-approval.tsx`, `clarify-tool.tsx`, `prompt-overlays.tsx`).
- Event-name enum: `apps/desktop/src/lib/gateway-events.ts` (`GatewayEventName`).

> **Key fact:** `/api/ws` drives the *same* `tui_gateway.dispatch` surface the terminal UI uses over
> stdio (`web_server.py:8094` — "Drives the same `tui_gateway.dispatch` surface Ink uses over
> stdio"). So the gateway method names and event payloads here are authoritative for both the
> dashboard Chat tab and the desktop app.

## Connection & auth

WebSocket URL (`web_server.py:_build_*` ~7882, `gateway-ws-url.ts`):

```
ws(s)://<host>/api/ws?token=<token>      # loopback / long-lived token (Talaria's case)
ws(s)://<host>/api/ws?ticket=<ticket>    # OAuth-gated remote; single-use, ~30s TTL
ws(s)://<host>/api/ws?internal=<cred>    # server-spawned children only; never used by Talaria
```

- **Token** is the same per-process dashboard session token Talaria already scrapes from the SPA
  (`_SESSION_TOKEN`, `web_server.py:139`; `DashboardTokenExtractor` / `DashboardSession` on our side).
  On all three Talaria paths the gateway is reached over loopback (local socket, `ssh -L` forward, or
  NIO-SSH `direct-tcpip` to `127.0.0.1`), so **token mode is sufficient** — Talaria never needs the
  `POST /api/auth/ws-ticket` ticket flow (that's only for non-loopback OAuth gateways).
- **Loopback gate:** a non-loopback client without a valid session is closed with code **4403**
  (`client_host_not_loopback`). Talaria satisfies this the same way it does for HTTP today.
- **Close codes:** `4400` missing required param, `4401` auth failed (bad/expired token/ticket),
  `4403` host/origin not allowed.
- **Connect timeout:** the desktop fails the open handshake after 15s (`gateway-ws-url` /
  `json-rpc-gateway.ts:DEFAULT_CONNECT_TIMEOUT_MS`). Request timeout default is **120s**.

## Envelope

Standard JSON-RPC 2.0 (`json-rpc-gateway.ts:33-39`, `handleMessage` 261-292).

**Client → server request:**
```json
{ "jsonrpc": "2.0", "id": "r1", "method": "prompt.submit", "params": { ... } }
```
- `id` is client-minted; the desktop uses string ids `"r1"`, `"r2"`, … (`createRequestId`, default
  prefix `r`). Any JSON-RPC id (string or number) works — the server echoes it back verbatim.

**Server → client, response (correlated by `id`):**
```json
{ "jsonrpc": "2.0", "id": "r1", "result": { ... } }
{ "jsonrpc": "2.0", "id": "r1", "error": { "message": "session busy" } }
```
- Exactly one of `result` / `error`. `error` is `{ "message"?: string }` (the client reads only
  `error.message`; server also sends an integer code via `_err(rid, <code>, msg)` but the desktop
  ignores it).

**Server → client, event notification (unsolicited, no `id`):**
```json
{ "jsonrpc": "2.0", "method": "event", "params": { "type": "<EventName>", "session_id": "ab12cd34", "payload": { ... } } }
```
- `frame.method === "event"` and `params.type` is set → it's an event (`handleMessage:289`).
- `params.session_id` is the **runtime** session id (the 8-hex id from `session.create`, *not* the
  stored DB id). Present on all streaming/turn events; may be `""` for global broadcasts.
- `params.payload` is the per-event data object (sometimes absent). **Note the nesting:** event
  fields live under `params.payload`, with `type`/`session_id` as siblings.

## Client → server methods

All confirmed from the server `@method(...)` handlers in `tui_gateway/server.py` and the desktop call
sites. `session_id` is the runtime id and is passed **in `params`**, never in the envelope.

| Method | params | result | Source |
|---|---|---|---|
| `session.create` | `{ cols?: int=80, cwd?: string, messages?: [], title?: string }` | `SessionCreateResponse` (below) | `server.py:2908`, `use-session-actions.ts:334` |
| `session.resume` | `{ session_id: string, cols?: int }` | `SessionResumeResponse` (below) | `server.py:3088`, `use-session-actions.ts:514` |
| `session.close` | `{ session_id: string }` | `{ ... }` | `server.py:3756`, `use-session-actions.ts:342` |
| `prompt.submit` | `{ session_id: string, text: string, truncate_before_user_ordinal?: int }` | `{ status: "streaming" }` (then events stream) | `server.py:4117`, `use-prompt-actions.ts:337` |
| `session.interrupt` | `{ session_id: string }` | `{ ... }` | `server.py:3834`, `use-prompt-actions.ts:744` |
| `approval.respond` | `{ session_id: string, choice: "once"\|"always"\|"deny", all?: bool=false }` | `{ resolved: bool }` | `server.py:5125`, `tool-approval.tsx:79` |
| `clarify.respond` | `{ request_id: string, answer: string }` | `{ status: "ok" }` | `server.py:5110`, `clarify-tool.tsx:119` |
| `sudo.respond` | `{ request_id: string, password: string }` | `{ status: "ok" }` | `server.py:5115`, `prompt-overlays.tsx:62` |
| `secret.respond` | `{ request_id: string, value: string }` | `{ status: "ok" }` | `server.py:5120`, `prompt-overlays.tsx:161` |

`approval.respond.choice` defaults to `"deny"` server-side (`server.py:5138`). The desktop sends
`"once"` for an immediate allow, `"deny"` to reject, and `"always"` (with the confirm dialog) to
allow-and-remember. `all: true` resolves *all* pending approvals at once.

The respond handlers (`clarify`/`sudo`/`secret`) are unified server-side as
`_respond(rid, params, key)` (`server.py:5098`): they look up `_pending[request_id]` and store
`params[key]`. So the field name **is** the `key` column above (`answer` / `password` / `value`).

### Session lifecycle (how Talaria will use it)

- A session is created over WS via **`session.create`** (or attached to an existing stored session via
  **`session.resume`**). It is *not* created via REST `/api/sessions` for live chat.
- `session.create` returns a runtime `session_id` (8 hex chars) **and** a `stored_session_id` (the DB
  id, only persisted lazily once the first `prompt.submit` lands). Talaria's `SessionId` should track
  the **runtime** id for live routing; the stored id is what `/api/sessions` and the sidebar use.
- One socket can host multiple sessions (events are `session_id`-keyed). For parity Talaria starts
  with the existing per-session ownership model and sends `session_id` on every call; socket
  multiplexing per window is a later optimization.

#### `SessionCreateResponse` (`types/hermes.ts:260`)
```ts
{ session_id: string, stored_session_id?: string, info?: SessionRuntimeInfo,
  message_count?: number, messages?: SessionMessage[] }
```
#### `SessionResumeResponse` (`types/hermes.ts:317`)
```ts
{ session_id: string, resumed: string, info?: SessionRuntimeInfo,
  message_count: number, messages: SessionMessage[] }
```
#### `SessionRuntimeInfo` (`types/hermes.ts:325`)
```ts
{ model?, provider?, cwd?, branch?, personality?, reasoning_effort?, service_tier?,
  fast?: bool, yolo?: bool, running?: bool, usage?: Partial<UsageStats>,
  credential_warning?, config_warning?, desktop_contract?: number, version?,
  skills?, tools? }
```

## Server → client events

The complete `GatewayEventName` set (`gateway-events.ts:1`):

```
gateway.ready  session.info  message.start  message.delta  message.complete
thinking.delta  reasoning.delta  reasoning.available  status.update
tool.start  tool.progress  tool.complete  tool.generating
clarify.request  approval.request  sudo.request  secret.request
background.complete  error  skin.changed
```

Plus a `subagent.*` family (`subagent.start`, `subagent.thinking`, `subagent.tool`,
`subagent.progress`, `subagent.complete`, `subagent.spawn_requested`) and a few niche ones
(`preview.restart.*`, `browser.progress`, `voice.*`) that the chat transcript does not need for
parity.

Payload fields are taken from the server `_emit(...)` call sites in `tui_gateway/server.py` and the
fields the desktop actually reads in `handleGatewayEvent`. **All fields are under `params.payload`.**

| Event | `payload` fields (server emit site) | Desktop consumption → Talaria mapping |
|---|---|---|
| `gateway.ready` | `{ skin? }` | Ignored (handshake only). |
| `session.info` | `SessionRuntimeInfo` (model, provider, cwd, branch, personality, reasoning_effort, service_tier, fast, yolo, running, usage, credential_warning, …) — `server.py:_session_info` | Drives model/provider/cwd/branch/usage badges + busy (`running`). → `.sessionUpdate(.sessionInfoUpdate)` + `.usageUpdate` when `usage` present. |
| `message.start` | `{}` (`server.py:4379`) | Turn busy **on**; reset streaming. → mark turn started. |
| `message.delta` | `{ text, rendered? }` (`server.py:4497`) | Append assistant text (`payload.text`). → `.sessionUpdate(.agentMessageChunk(text))`. |
| `message.complete` | `{ text, usage, status: "complete"\|"interrupted"\|"error", rendered?, reasoning?, warning? }` (`server.py:4577`) | Finalize assistant bubble with `text \|\| rendered`; apply `usage`; `status` → stop reason. → completes the `prompt` call (stop reason from `status`) + `.usageUpdate`. |
| `thinking.delta` | `{ text }` (`server.py:2076`) | **Ignored** — this is the kawaii spinner status, not real reasoning (`use-message-stream.ts:737`). Do **not** map. |
| `reasoning.delta` | `{ text, verbose? }` (`server.py:2077`) | Append reasoning (`payload.text`). → `.sessionUpdate(.agentThoughtChunk(text))`. |
| `reasoning.available` | `{ text, verbose? }` (`server.py:2001`) | Desktop **replaces** the reasoning block with `payload.text`. Talaria's thought stream is append-only, so the full text is emitted as `.agentThoughtChunk` **only when no `reasoning.delta` streamed this turn** — otherwise it's dropped to avoid duplicating the already-streamed reasoning. |
| `status.update` | `{ kind, text? }` (`server.py:489`, e.g. `kind:"process"`) | Status line / busy hint. → optional status event; not required for parity. |
| `tool.start` | `{ tool_id, name, context, args_text? }` (`server.py:1921`) — **no `args`** | Upsert tool row (running). → `.sessionUpdate(.toolCall)` status `in_progress`, `toolCallId=tool_id`, `title=name`, raw input from `context`/`args_text`. |
| `tool.progress` | id-less progress (rarely emitted for tools; see `_on_tool_progress`) | Same family as `tool.start`. → `.toolCallUpdate` (best-effort). |
| `tool.generating` | `{ name }` (`server.py:2075`) | Pre-call "generating args" hint. → optional; ignorable for parity. |
| `tool.complete` | `{ tool_id, name, args, result, duration_s?, summary?, result_text?, todos?, inline_diff? }` (`server.py:1936`) | Upsert tool row (complete); `inline_diff` (string) → diff view. → `.sessionUpdate(.toolCallUpdate)` status `completed`; `inline_diff` → `ToolCallContent.diff`; `result`/`summary` → content. |
| `clarify.request` | `{ request_id, question, choices? }` (agent clarify tool) | Park clarify overlay; agent **blocks** on `clarify.respond`. → `.permissionRequest` (or clarify prompt) with `request_id`; respond via `clarify.respond`. |
| `approval.request` | `{ command?, description? }` (`server.py:675`/`2556`) | Park approval overlay; agent **blocks** on `approval.respond`. → `.permissionRequest`; respond via `approval.respond {choice}`. |
| `sudo.request` | `{ request_id, text? }` | Park sudo-password overlay; blocks on `sudo.respond`. → `.permissionRequest` (secure text); respond via `sudo.respond {request_id, password}`. |
| `secret.request` | `{ request_id, env_var?, prompt? }` | Park secret-capture overlay; blocks on `secret.respond`. → `.permissionRequest` (secure text); respond via `secret.respond {request_id, value}`. |
| `error` | `{ message }` (`server.py:4714`, `4160`) | Fail current turn + surface error. → `.clientRequestError` / fail the `prompt` call. |
| `background.complete` | notification | Background task done; not needed for chat parity. → log/ignore. |
| `skin.changed` | `{ skin? }` (`server.py:5554`) | Theme change. → ignore. |
| `subagent.*` | spawn-tree payloads (`goal`, `task_count`, `task_index`, …) | Subagent sidebar. → out of scope for v1 parity; log/ignore. |

### Mapping to Talaria's `HermesNotification` contract

The migration's invariant: `GatewayChatClient` must emit the **same** `HermesNotification` values the
ACP `HermesClient` emits, so `LocalChatViewModel` / `ChatView` are unchanged. Concretely:

- `message.delta` → `.sessionUpdate(SessionNotification(sessionId, .agentMessageChunk(Content(.text(text)))))`
- `reasoning.delta` → `.sessionUpdate(... .agentThoughtChunk(...))`; `reasoning.available` → same, but suppressed when deltas already streamed this turn (append-only stream, no replace)
- `tool.start` → `.sessionUpdate(... .toolCall(ToolCall(toolCallId: tool_id, title: name, status: .inProgress, ...)))`
- `tool.complete` → `.sessionUpdate(... .toolCallUpdate(ToolCallUpdate(toolCallId: tool_id, status: .completed, content: [.diff(...)] or [.content(...)])))`
- `session.info` → `.sessionUpdate(... .sessionInfoUpdate(...))` and, when `usage` present, `.sessionUpdate(... .usageUpdate(...))`
- `approval.request` / `sudo.request` / `secret.request` / `clarify.request` → `.permissionRequest(PermissionRequestEvent(...))` whose `respond` callback sends the matching `*.respond` method back over WS
- `message.complete` resolves the in-flight `prompt(...)` call with a `PromptResponse(stopReason:)` derived from `status`; `error` rejects it / emits `.clientRequestError`
- `gateway.ready` is the handshake; `thinking.delta`, `skin.changed`, `background.complete`, `subagent.*` are ignored for v1 parity

## Voice APIs (documented, NOT implemented in Talaria)

The desktop voice mode uses two dashboard **REST** routes (not WS). Documented here for completeness;
Talaria does not implement voice in v1.

- **`POST /api/audio/transcribe`** — request `{ data_url: "data:audio/wav;base64,…", mime_type }`;
  response `{ ok: bool, transcript: string, provider: string }` (`hermes.ts:640`).
- **`POST /api/audio/speak`** — request `{ text }`; response
  `{ ok: bool, data_url: "data:audio/mp3;base64,…", mime_type, provider }` (`hermes.ts:651`).
- Desktop flow: record → `transcribe` → feed transcript as a normal `prompt.submit`; on a
  voice-mode turn end, `speak` the response and play the returned `data_url`. The gateway also emits
  `voice.transcript` / `voice.status` events (`server.py:7469`) when the server-side mic loop is
  active, which Talaria would consume if/when voice ships.

## Implementation status — WebSocket is the only chat path

Live chat is WebSocket-only; the ACP subprocess + byte-`Transport` stack has been removed
(`HermesClient`, `LocalProcessTransport`, `SSHTransport`, `NIOSSHTransport`, the `Transport` protocol,
the `useGatewayChat` flag, the version gate, and the ACP/WS badge are all gone).

- **HermesKit:** `GatewayChatClient` (event→`HermesNotification` mapping, turn lifecycle, approval
  round-trip) is the sole chat client, behind the thin `ChatBackend` seam (kept only as the test/mock
  point). `GatewayWebSocket` + `URLSessionGatewayWebSocket` (macOS) / `NIOSSHGatewayWebSocket` (iOS,
  RFC 6455 via `GatewayWebSocketHandshake` + swift-nio frame codecs over a persistent `direct-tcpip`
  channel). `SessionManager` boots one `GatewayChatClient` per session.
- **macOS:** `GatewayChatBackend.makeFactory` opens the socket on the window's shared, refcounted
  `hermes dashboard` (local + `ssh -L` remote both expose a loopback socket).
- **iOS:** chat tunnels `/api/ws` over the window's live NIO-SSH dashboard connection
  (`NIOSSHGatewayWebSocket` over the `GatewayChatTunnel` the harness fills in `acquireDashboard()`).
  There is no fallback — a session opened before the dashboard is up errors and the user retries.

Verified by unit tests (`GatewayChatClientTests`, `GatewayWebSocketHandshakeTests`, `SessionManagerTests`)
+ macOS/iOS app builds. The end-to-end SSH tunnel (iOS) still needs live on-device verification.

## Remaining work

- **Text-input prompts:** free-text `clarify` / `sudo` / `secret` map to the option-only permission
  UI today (approval is full parity); a secure text-input affordance is needed for full capture.
- **Socket multiplexing / `status.update` / `tool.generating` / subagent sidebar:** later enhancements.
