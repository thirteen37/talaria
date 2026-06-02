# Talaria vs. other Hermes front-ends

This document positions Talaria against the other ways to drive [Hermes
Agent](https://github.com/NousResearch/hermes-agent) through a GUI. It is a
snapshot of a moving field (every project here ships frequently) and is written
to be honest about where Talaria leads and where it trails, not to market. When
a row is wrong, fix it — Hermes and the upstream projects are the source of
truth, this file is the thing that's out of date.

## The field

| Project | Form factor | Platforms | Talks to Hermes via | License |
| --- | --- | --- | --- | --- |
| **Talaria** | Native SwiftUI app | macOS (shared iOS target in progress) | Dashboard HTTP API + a few CLI fallbacks; **never** reads Hermes files/DB directly (one read-only `.env` enumerate exception) | Source-available |
| **[Hermes Desktop][hermes-desktop]** (Nous Research, official) | Cross-platform GUI (Electron-class) | macOS, Windows, Linux | Bundled on the same Hermes core engine | MIT |
| **[Hermes built-in dashboard][hermes-dashboard]** (`hermes dashboard`) | Local web app (FastAPI + SPA) | Any browser | In-process — it *is* part of Hermes (`hermes_cli/web_server.py`) | Ships with Hermes |
| **[Scarf][scarf]** (awizemann) | Native SwiftUI app | macOS 14.6+, iOS (ScarfGo, TestFlight) | ACP + **direct read-only SQLite** + file watching + CLI subprocess | Source-available |
| **[hermes-workspace][hermes-workspace]** (outsourc-e) | Web app / PWA (React/TS) | Browser, installable PWA, Docker | Gateway HTTP (8642) + dashboard HTTP (9119) | MIT |

A handful of read-only web dashboards also exist (e.g.
[`mayurjobanputra/hermes-dashboard`][mayur], [`EKKOLearnAI/hermes-web-ui`][ekko],
[`chrisryugj/hermes-dashboard`][chris], [`nesquena/hermes-webui`][nesquena]).
They overlap heavily with the built-in dashboard and are not tracked row-by-row here.

[hermes-desktop]: https://www.hermes-ai.net/desktop/
[hermes-dashboard]: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
[scarf]: https://github.com/awizemann/scarf
[hermes-workspace]: https://github.com/outsourc-e/hermes-workspace
[mayur]: https://github.com/mayurjobanputra/hermes-dashboard
[ekko]: https://github.com/EKKOLearnAI/hermes-web-ui
[chris]: https://github.com/chrisryugj/hermes-dashboard
[nesquena]: https://github.com/nesquena/hermes-webui

## What makes Talaria different

Talaria's defining choice is its **integration boundary**, not its feature count.

- **Dashboard-API-only data path.** Every non-chat surface goes through
  `hermes dashboard` HTTP routes; live chat goes through ACP/JSON-RPC. Talaria
  does **not** open Hermes' `state.db`, parse `cron/jobs.json`, or write
  `config.yaml`/memory files behind Hermes' back. The single documented
  exception is reading `.env` read-only to *enumerate* user-named custom vars
  the API doesn't list — all `.env` **writes** still go through the API. See
  `docs/security.md` and `docs/dashboard-api.md`.

  This is the sharpest contrast with **Scarf**, which reads `state.db` directly
  (read-only SQLite, WAL mode), watches YAML/JSON/Markdown on disk, and writes
  memory and settings files itself. Scarf's approach exposes more data with less
  Hermes cooperation; Talaria's stays inside the contract Hermes actually
  supports, so the same code path works identically local and remote and doesn't
  break when Hermes changes its on-disk schema.

- **The same path works local and remote.** Because everything is HTTP to a
  loopback port, remote is just "run `hermes dashboard` over SSH and forward the
  port." macOS uses system `ssh -L`; iOS uses a pure-Swift NIO-SSH
  `direct-tcpip` tunnel (no `ssh` binary, no local forward). There is no
  separate "remote reads SQLite over SSH" path to maintain.

- **One window = one server profile.** Each window owns its ACP clients,
  dashboard client, CLI runner, version cache, and capability table.
  `DashboardCoordinator` shares one `hermes dashboard` child per
  `(ServerProfile, Hermes profile)` pair and reference-counts it.

- **Capability-gated on the connected Hermes version.** Surfaces that need a
  newer Hermes (e.g. dashboard, model API, env API all need `≥ 0.14.0`) show a
  "dashboard required" banner below the gate rather than breaking; ACP chat
  keeps working. See `docs/integration-coverage.md`.

- **Native, signed, notarized.** Hardened Runtime + Developer-ID signing +
  notarization + Sparkle auto-update. Not Electron, not a browser tab.

Scarf shares the "native SwiftUI, multi-window, multi-server over SSH" shape —
it is Talaria's closest peer — but takes the opposite stance on the data
boundary. Hermes Desktop is the official cross-platform GUI but is broader and
less Mac-native. The web UIs (built-in dashboard, hermes-workspace) win on "open
in any browser, including from a phone" and lose on native feel and offline
integration.

## Feature comparison

✅ shipped · 🟡 partial · ⬜ not present · — n/a

| Capability | Talaria | Hermes Desktop | Built-in dashboard | Scarf | hermes-workspace |
| --- | :---: | :---: | :---: | :---: | :---: |
| Live chat (rich, streaming) | ✅ ACP | ✅ | ✅ SSE | ✅ ACP | ✅ SSE |
| Terminal / TUI escape hatch | ⬜ | 🟡 | ⬜ | ✅ SwiftTerm | ✅ PTY |
| Sessions browse / search / read | ✅ | ✅ | ✅ | ✅ | ✅ |
| Session rename / delete | ✅ (rename via CLI) | ✅ | ✅ | ✅ | 🟡 |
| Session JSONL export | ⬜ | ? | ⬜ | ✅ | ⬜ |
| Skills list / toggle | ✅ | ✅ | ✅ | ✅ | ✅ |
| Skills Hub install / search | ✅ (search HTTP, install CLI) | ✅ | ✅ | ✅ | ✅ (2,000+) |
| Plugins install / enable / update | ✅ | 🟡 | ✅ | ✅ | 🟡 |
| Tools enable / disable | ✅ (CLI) | ✅ | 🟡 list-only | ✅ | 🟡 |
| MCP server registry / presets | ⬜ | ✅ | ✅ | ✅ | ✅ |
| Cron full CRUD | ✅ | 🟡 | ✅ | ✅ | 🟡 |
| Kanban board (multi-agent) | ✅ full CRUD | ⬜ | ✅ | 🟡 project dash | ✅ |
| Models: main + auxiliary slots | ✅ | ✅ switch | ✅ | ✅ + aux settings | ✅ |
| Custom OpenAI-compatible endpoints | ✅ | 🟡 | 🟡 | 🟡 | ✅ |
| Gateway start / stop / status | ✅ (CLI) | ✅ | 🟡 | ✅ | ✅ |
| Messaging-platform setup forms | ⬜ | ✅ 15+ | 🟡 | ✅ 13 | 🟡 |
| Soul / personality editor | ✅ both | 🟡 | 🟡 | ✅ both | ⬜ |
| Memory (`MEMORY.md`/`USER.md`) editor | ⬜ | ✅ | 🟡 | ✅ | ✅ |
| Config editor (schema-driven) | ✅ | 🟡 | ✅ | ✅ 10-tab | ✅ |
| Environment (`.env`) CRUD | ✅ | 🟡 | ✅ | ✅ | 🟡 |
| Logs viewer (filter / tail) | ✅ | 🟡 | ✅ | ✅ session pills | 🟡 |
| Doctor / health diagnostics | ✅ (CLI) | 🟡 | ✅ | ✅ + audit | 🟡 |
| Updates (self-update) | ✅ Sparkle + Hermes | ✅ | ✅ | ✅ Sparkle | 🟡 |
| Hermes profile clone / rename / delete | ✅ | 🟡 | ✅ | ✅ + export/import | ✅ presets |
| Usage insights / token cost analytics | ⬜ | ✅ | ✅ | ✅ heatmaps | ✅ ledger |
| Activity feed / tool-call log | ⬜ | 🟡 | 🟡 | ✅ | ✅ |
| Credential pools / rotation | ⬜ | 🟡 | ⬜ | ✅ | ⬜ |
| Webhooks management | ⬜ | 🟡 | ⬜ | ✅ | ⬜ |
| Quick commands (custom `/cmd`) | ⬜ | 🟡 | ⬜ | ✅ | ⬜ |
| Hermes Proxy (OpenAI-compatible) | ⬜ | 🟡 | ⬜ | ✅ | ✅ swarm |
| Multi-window / multi-server | ✅ | 🟡 | ⬜ tab | ✅ | 🟡 |
| Remote over SSH | ✅ system+NIO | ? | ⬜ (you forward) | ✅ + Citadel | 🟡 Tailscale |
| Customizable sidebar (reorder/hide) | ✅ | ? | ⬜ | 🟡 | 🟡 themes |
| iOS / iPhone companion | 🟡 in progress | ⬜ | 🟡 PWA | ✅ ScarfGo | ✅ PWA |

`?` = couldn't confirm from public material at time of writing. Hermes Desktop is
"coming soon" as of this writing, so several of its cells are marketing claims,
not verified behavior.

## Where Talaria is ahead

- **Cleanest integration contract.** Nothing reaches around Hermes into its
  database or config files. This is the most forward-compatible posture of any
  app here and the only one that is *identical* whether the server is local or a
  remote box over SSH.
- **First-class iOS remoting model.** The pure-Swift NIO-SSH `direct-tcpip`
  tunnel reuses the chat transport's host-key trust to bring the *full*
  dashboard surface to iOS, not a reduced read-only subset. (Scarf's ScarfGo is
  the only comparable mobile effort and is also strong here.)
- **Customizable Browse sidebar** that persists and is shared between the
  desktop sidebar and the iPhone Browse sheet.
- **Kanban with full CRUD** (boards, tasks, links, comments, bulk ops, run logs,
  diagnostics) wired straight to the Hermes kanban plugin API.

## Where Talaria trails (honest gaps)

These are present in one or more competitors and absent from Talaria today.
Several are tracked in `docs/roadmap.md` as deliberately deferred:

- **No usage insights / token-cost analytics.** Scarf, the built-in dashboard,
  and hermes-workspace all chart token usage and cost; Talaria does not.
- **No MCP server registry.** No browse/add/preset flow for MCP servers — a
  notable gap, since Scarf, Hermes Desktop, and the built-in dashboard all have
  one.
- **No messaging-platform setup forms.** Scarf configures 13 platforms with
  native forms; Hermes Desktop pitches a 15+ platform unified inbox. Talaria
  exposes none of this yet.
- **No memory editor.** Talaria edits Soul and Personalities but not
  `MEMORY.md` / `USER.md`.
- **No terminal escape hatch, activity feed, credential pools, webhooks, quick
  commands, or Hermes Proxy UI.**

## Takeaway

Pick **Talaria** if you want a focused, native-Mac (and soon iOS) client with a
strict, forward-compatible boundary to Hermes and clean SSH remoting. Pick
**[Scarf][scarf]** if you want the broadest native-Mac feature set today and
don't mind it reading Hermes' database directly. Pick **[Hermes
Desktop][hermes-desktop]** for an official, cross-OS (Windows/Linux included)
app. Pick the **[built-in dashboard][hermes-dashboard]** or
**[hermes-workspace][hermes-workspace]** if a browser/PWA that runs anywhere
matters more than native feel.
