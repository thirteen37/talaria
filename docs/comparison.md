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
| **Talaria** | Native SwiftUI app | macOS (shared iOS target in progress) | Dashboard HTTP API + a few CLI fallbacks; **never** reads Hermes DB directly. Direct file I/O is limited to documented gaps: read-only `.env` enumeration and `MEMORY.md` / `USER.md` editing. | MIT |
| **[Hermes Desktop · Nous Research][hermes-desktop]** — *first-party / official flagship* | Cross-platform desktop app (Electron + React; Python backend that reuses the Hermes TUI/CLI) | macOS 12+, Windows 10/11, Linux | The **same agent core** as the CLI/gateway via standard gateway APIs — shared config, API keys, sessions, skills, and memory; history carries across surfaces | MIT |
| **[Hermes Desktop · fathah][hermes-desktop-fathah]** — *third-party, unofficial* | Cross-platform desktop app (Electron 39 + React 19 + TypeScript) | macOS, Windows, Linux, Fedora (RPM), WSL | Gateway/CLI plus a bundled SQLite layer (`better-sqlite3`) | MIT |
| **[Hermes built-in dashboard][hermes-dashboard]** (`hermes dashboard`) | Local web app (FastAPI + SPA) | Any browser | In-process — it *is* part of Hermes (`hermes_cli/web_server.py`) | Ships with Hermes |
| **[Scarf][scarf]** (awizemann) | Native SwiftUI app | macOS 14.6+, iOS (ScarfGo, TestFlight) | ACP + **direct read-only SQLite** + file watching + CLI subprocess | Source-available |
| **[hermes-workspace][hermes-workspace]** (outsourc-e) | Web app / PWA (React/TS) | Browser, installable PWA, Docker | Gateway HTTP (8642) + dashboard HTTP (9119) | MIT |

A handful of read-only web dashboards also exist (e.g.
[`mayurjobanputra/hermes-dashboard`][mayur], [`EKKOLearnAI/hermes-web-ui`][ekko],
[`chrisryugj/hermes-dashboard`][chris], [`nesquena/hermes-webui`][nesquena]).
They overlap heavily with the built-in dashboard and are not tracked row-by-row here.

**Two unrelated projects share the name "Hermes Desktop."** One is Nous
Research's own **first-party** flagship GUI ([hermes-agent.nousresearch.com/desktop][hermes-desktop]);
the other is an independent **third-party** app by @fathah
([github.com/fathah/hermes-desktop][hermes-desktop-fathah]). They are completely
separate codebases that happen to share a name — both are Electron + React and
MIT-licensed — and this doc tracks them as distinct entries. Aside from the Nous
app and the built-in dashboard (which ships inside Hermes), everything here —
**Talaria included** — is a third-party client.

[hermes-desktop]: https://hermes-agent.nousresearch.com/desktop
[hermes-desktop-fathah]: https://github.com/fathah/hermes-desktop
[hermes-dashboard]: https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard
[scarf]: https://github.com/awizemann/scarf
[hermes-workspace]: https://github.com/outsourc-e/hermes-workspace
[mayur]: https://github.com/mayurjobanputra/hermes-dashboard
[ekko]: https://github.com/EKKOLearnAI/hermes-web-ui
[chris]: https://github.com/chrisryugj/hermes-dashboard
[nesquena]: https://github.com/nesquena/hermes-webui

## What makes Talaria different

Talaria's defining choice is its **integration boundary**, not its feature count.

- **Dashboard-first data path.** Every non-chat surface goes through
  `hermes dashboard` HTTP routes; live chat rides the same dashboard over its
  `/api/ws` gateway (JSON-RPC 2.0 over WebSocket). Talaria
  does **not** open Hermes' `state.db`, parse `cron/jobs.json`, or write
  `config.yaml` behind Hermes' back. The documented direct-file exceptions are:
  reading `.env` read-only to *enumerate* user-named custom vars the API doesn't
  list (all `.env` **writes** still go through the API), and editing
  `MEMORY.md` / `USER.md` because Hermes exposes only provider status over the
  dashboard today. See
  `docs/security.md` and `docs/dashboard-api.md`.

  This is the sharpest contrast with **Scarf**, which reads `state.db` directly
  (read-only SQLite, WAL mode), watches YAML/JSON/Markdown on disk, and writes
  memory and settings files itself. Scarf's approach exposes more data with less
  Hermes cooperation; Talaria's stays inside the contract Hermes actually
  supports; the few direct-file paths are isolated, documented, and use the same
  local/remote file-store abstraction rather than touching SQLite internals.

- **The same path works local and remote.** Because everything is HTTP to a
  loopback port, remote is just "run `hermes dashboard` over SSH and forward the
  port." macOS uses system `ssh -L`; iOS uses a pure-Swift NIO-SSH
  `direct-tcpip` tunnel (no `ssh` binary, no local forward). There is no
  separate "remote reads SQLite over SSH" path to maintain.

- **One window = one server profile.** Each window owns its chat clients (over
  the dashboard gateway), dashboard client, CLI runner, version cache, and
  capability table.
  `DashboardCoordinator` shares one `hermes dashboard` child per
  `(ServerProfile, Hermes profile)` pair and reference-counts it.

- **Capability-gated on the connected Hermes version.** Surfaces that need a
  newer Hermes (e.g. dashboard, model API, env API all need `≥ 0.14.0`) show a
  "dashboard required" banner below the gate rather than breaking. Live chat now
  rides that same dashboard gateway, so it needs the dashboard too. See
  `docs/integration-coverage.md`.

- **Native, signed, notarized.** Hardened Runtime + Developer-ID signing +
  notarization + Sparkle auto-update. Not Electron, not a browser tab — unlike
  *both* apps named "Hermes Desktop" (the official Nous one and the third-party
  fathah one are each Electron + React).

Scarf shares the "native SwiftUI, multi-window, multi-server over SSH" shape —
it is Talaria's closest peer — but takes the opposite stance on the data
boundary. The **official Hermes Desktop** (Nous Research) is the flagship GUI —
it shipped as a public preview (v0.15.2) on 2 June 2026 — and because it's
first-party it runs the *same* agent core as the CLI and gateway, so config,
sessions, skills, and memory carry across surfaces; it leads on breadth
(macOS/Windows/Linux, a right-hand preview rail, file browser, voice mode, image
generation, 300+ models via the Nous Portal). The **third-party Hermes Desktop**
by @fathah is a separate Electron app with its own strengths — full-text (FTS5)
session search, a memory editor, a SOUL.md persona editor, live token/cost
display, credential pools, and 16 messaging gateways. Both are cross-OS Electron
apps rather than Mac-native,
and neither offers Talaria's SSH-remoting-to-another-box model. The web UIs
(built-in dashboard, hermes-workspace) win on "open in any browser, including
from a phone" and lose on native feel and offline integration.

## Feature comparison

✅ shipped · 🟡 partial · ⬜ not present · — n/a

| Capability | Talaria | HD · Nous (official) | HD · fathah (3rd-party) | Built-in dashboard | Scarf | hermes-workspace |
| --- | :---: | :---: | :---: | :---: | :---: | :---: |
| Live chat (rich, streaming) | ✅ gateway WS | ✅ streaming | ✅ streaming | ✅ SSE | ✅ ACP | ✅ SSE |
| Terminal / TUI escape hatch | ✅ SwiftTerm (macOS) | 🟡 TUI backend | ⬜ | ⬜ | ✅ SwiftTerm | ✅ PTY |
| Sessions browse / search / read | ✅ | ✅ | ✅ full-text | ✅ | ✅ | ✅ |
| Session rename / delete | ✅ (rename via CLI) | 🟡 | 🟡 | ✅ | ✅ | 🟡 |
| Session JSONL export | ⬜ | ? | ? | ⬜ | ✅ | ⬜ |
| Skills list / toggle | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Skills Hub install / search | ✅ (search HTTP, install CLI) | ✅ | ✅ | ✅ | ✅ | ✅ (2,000+) |
| Plugins install / enable / update | ✅ | 🟡 | 🟡 | ✅ | ✅ | 🟡 |
| Tools enable / disable | ✅ (CLI) | ✅ | ✅ 14 toolsets | 🟡 list-only | ✅ | 🟡 |
| MCP server registry / presets | ✅ + catalog, test | ✅ | ? | ✅ | ✅ | ✅ |
| Cron full CRUD | ✅ | ✅ | ✅ | ✅ | ✅ | 🟡 |
| Kanban board (multi-agent) | ✅ full CRUD | 🟡 Agents/Command Center | ⬜ | ✅ | 🟡 project dash | ✅ |
| Models: main + auxiliary slots | ✅ | ✅ | ✅ | ✅ | ✅ + aux settings | ✅ |
| Custom OpenAI-compatible endpoints | ✅ | ✅ | ✅ | 🟡 | 🟡 | ✅ |
| Gateway start / stop / status | ✅ (CLI) | ✅ | 🟡 | 🟡 | ✅ | ✅ |
| Messaging-platform setup forms | ✅ 8 + auto | ✅ | ✅ 16 | 🟡 | ✅ 13 | 🟡 |
| Soul / personality editor | ✅ both | 🟡 | ✅ SOUL.md | 🟡 | ✅ both | ⬜ |
| Memory (`MEMORY.md`/`USER.md`) editor | ✅ | 🟡 | ✅ | 🟡 | ✅ | ✅ |
| Config editor (schema-driven) | ✅ | ✅ | 🟡 | ✅ | ✅ 10-tab | ✅ |
| Environment (`.env`) CRUD | ✅ | 🟡 | 🟡 | ✅ | ✅ | 🟡 |
| Logs viewer (filter / tail) | ✅ | 🟡 | ✅ | ✅ | ✅ session pills | 🟡 |
| Doctor / health diagnostics | ✅ (CLI) | 🟡 | ? | ✅ | ✅ + audit | 🟡 |
| Updates (self-update) | ✅ Sparkle + Hermes | ✅ one-click | ✅ auto | ✅ | ✅ Sparkle | 🟡 |
| Hermes profile clone / rename / delete | ✅ | 🟡 switch | ✅ multi-profile | ✅ | ✅ + export/import | ✅ presets |
| Profile **distributions** (install / update / export / publish) | ✅ install·update·info·export·import·author·**publish to git** | ? | ? | ⬜ | 🟡 export/import (zip) | ? |
| Usage insights / token cost analytics | ✅ tokens + cost | 🟡 | ✅ tokens + cost | ✅ | ✅ heatmaps | ✅ ledger |
| Activity feed / tool-call log | ⬜ | 🟡 live tool activity | 🟡 tool progress | 🟡 | ✅ | ✅ |
| Credential pools / rotation | ⬜ | ⬜ | ✅ pools | ⬜ | ✅ | ⬜ |
| Webhooks management | ⬜ | ⬜ | ⬜ | ⬜ | ✅ | ⬜ |
| Quick commands (custom `/cmd`) | ⬜ | ? | 🟡 slash cmds | ⬜ | ✅ | ⬜ |
| Hermes Proxy (OpenAI-compatible) | ⬜ | ? | ⬜ | ⬜ | ✅ | ✅ swarm |
| Multi-window / multi-server | ✅ | 🟡 | 🟡 | ⬜ tab | ✅ | 🟡 |
| Remote over SSH | ✅ system+NIO | ? | ? | ⬜ (you forward) | ✅ + Citadel | 🟡 Tailscale |
| Customizable sidebar (reorder/hide) | ✅ | ? | ? | ⬜ | 🟡 | 🟡 themes |
| iOS / iPhone companion | 🟡 in progress | ⬜ | ⬜ | 🟡 PWA | ✅ ScarfGo | ✅ PWA |

`?` = couldn't confirm from public material. The two "Hermes Desktop" columns are
separate projects (see above): **HD · Nous** is the official app (public preview
v0.15.2, shipped 2 June 2026); **HD · fathah** is the unofficial third-party app.
Most of their cells come from launch announcements and READMEs, not hands-on
testing. The Nous app also ships voice mode, image generation, a preview rail and
file browser that have no row here; fathah's app adds a "Hermes Office" 3D view.

## Where Talaria is ahead

- **Cleanest integration contract.** Talaria does not read Hermes' database or
  write Hermes config files directly. The remaining direct-file edits are
  limited to the memory files Hermes does not yet expose as mutable dashboard
  resources. This is still the most forward-compatible posture of any app here
  and the only one that is *identical* whether the server is local or a remote
  box over SSH.
- **First-class iOS remoting model.** The pure-Swift NIO-SSH `direct-tcpip`
  tunnel reuses the chat transport's host-key trust to bring the *full*
  dashboard surface to iOS, not a reduced read-only subset. (Scarf's ScarfGo is
  the only comparable mobile effort and is also strong here.)
- **Customizable Browse sidebar** that persists and is shared between the
  desktop sidebar and the iPhone Browse sheet.
- **Kanban with full CRUD** (boards, tasks, links, comments, bulk ops, run logs,
  diagnostics) wired straight to the Hermes kanban plugin API.
- **Full profile-distribution lifecycle — including authoring and publishing.**
  Talaria takes a distribution all the way around the loop: **install** one from
  a git URL or local dir, **update** (re-pull) it, view its **manifest**,
  **export/import** a profile as a portable `.tar.gz`, **author** its
  `distribution.yaml` in a form editor, and **publish** it to git (Talaria runs
  `git init/add/commit/tag/push` on the host). Among the clients tracked here,
  Scarf is the only other one that touches this area at all — and only as profile
  **export/import** (zip), not git install or publish; the official and
  third-party Hermes Desktop apps and hermes-workspace don't mention
  distributions in their public material (so those cells are `?`, not confirmed
  absences). And like every Talaria surface it works **identically on macOS and
  iOS** and against a local or SSH-remote Hermes — the git/archive work runs on
  whichever host the profile lives on, over the same transport everything else
  uses. (These are CLI-driven: Hermes exposes no dashboard route for `profile
  install/update/export/import`, so they ride the admin runner like the Skills
  Hub mutations.)

## Where Talaria trails (honest gaps)

These are present in one or more competitors and absent from Talaria today.
Several are tracked in `docs/roadmap.md` as deliberately deferred:

- **No activity feed, credential pools, webhooks, quick commands, or Hermes
  Proxy UI.** (A terminal/TUI escape hatch *has* shipped on macOS — chats can be
  opened as the real `hermes chat --tui` in an embedded SwiftTerm terminal.)

## Takeaway

Pick **Talaria** if you want a focused, native-Mac (and soon iOS) client with a
strict, documented boundary to Hermes and clean SSH remoting — and the fullest
profile-**distribution** workflow here, from installing one off git to authoring
its `distribution.yaml` and publishing it back (Scarf does profile export/import;
the other GUIs don't document distribution support either way). Pick
**[Scarf][scarf]** if you want the broadest native-Mac feature set today and
don't mind it reading Hermes' database directly. Pick the **official [Hermes
Desktop][hermes-desktop]** — Nous Research's own first-party app — if you want
the cross-OS (Windows/Linux included) GUI with voice, image generation, and 300+
Portal models, and don't need Mac-native polish or SSH remoting. (The unrelated
third-party **[Hermes Desktop by @fathah][hermes-desktop-fathah]** is a different
Electron app of the same name, with full-text session search, a memory editor,
and a 3D "Hermes Office" view.) Pick the **[built-in dashboard][hermes-dashboard]** or
**[hermes-workspace][hermes-workspace]** if a browser/PWA that runs anywhere
matters more than native feel.
