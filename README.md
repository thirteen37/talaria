# Talaria

Talaria is a native SwiftUI front-end for [Hermes Agent](https://github.com/NousResearch/hermes-agent) — macOS today, with an in-progress iOS/iPadOS target sharing the same source tree behind platform-seam folders. Shared protocol and transport code lives in the `HermesKit` Swift package.

Hermes has a crowded GUI ecosystem — Nous Research's official Electron [Hermes Desktop](https://hermes-agent.nousresearch.com/desktop), the built-in `hermes dashboard`, a long tail of browser/PWA front-ends, and a few native-Swift apps. Talaria's pitch is **a focused, genuinely native client that stays inside the contract Hermes actually supports** and reaches a remote Hermes box exactly the way it reaches a local one.

## What makes Talaria distinct

- **Native and notarized — not a web wrapper.** SwiftUI throughout, with Hardened Runtime, Developer-ID signing, notarization, and Sparkle auto-update. Both desktop apps that carry the "Hermes Desktop" name (Nous Research's official one and an [unrelated third-party app](https://github.com/fathah/hermes-desktop)) are Electron + React; the built-in dashboard and most community front-ends are a browser tab or PWA.

- **A strict dashboard-contract boundary.** Every surface goes through `hermes dashboard` — non-chat screens over its HTTP API, live chat over its `/api/ws` JSON-RPC gateway. Talaria never opens Hermes' `state.db`, parses `cron/jobs.json`, or writes `config.yaml` behind Hermes' back. That makes it the most forward-compatible posture among native clients: the closest peers, [Scarf](https://github.com/awizemann/scarf) (reads `state.db` directly and watches files on disk) and [dodo-reach/hermes-desktop](https://github.com/dodo-reach/hermes-desktop) (drives pure SSH with no gateway at all), each take the opposite bet. The few direct-file exceptions are deliberate and documented, and are either read-only or route writes back through the sanctioned API: read-only `.env` enumeration, the `MEMORY.md`/`USER.md` editor, and the Hindsight reads below. See [`docs/security.md`](docs/security.md).

- **The same path works local and remote.** Because everything is HTTP to a loopback port, "remote" is just *run `hermes dashboard` over SSH and forward the port* — there's no separate "read the database over SSH" path to maintain. macOS uses system `ssh -L`; iOS/iPadOS uses a pure-Swift NIO-SSH `direct-tcpip` tunnel (no `ssh` binary) that brings the **full** dashboard surface to mobile, not a cut-down read-only subset.

- **The fullest profile-distribution workflow in the field.** Talaria takes a distribution all the way around the loop — install or update one from a git URL, view its manifest, export/import a profile as a portable `.tar.gz`, author its `distribution.yaml` in a form editor, and **publish it back to git** — on macOS and iOS, local or remote. The closest, Scarf, does profile export/import (zip) but not git install or publish; the other clients don't document distributions at all. See [`docs/profile-distributions.md`](docs/profile-distributions.md).

- **A read-only Hindsight memory browser.** When Hindsight is the active memory provider, Talaria lists and semantically searches its vector store by talking to Hindsight's own REST API — the embedded daemon over localhost (tunneled for remote profiles) or Hindsight Cloud — since Hermes exposes no route to browse it. No other client surfaces this.

- **Polished where it counts.** Capability-gated on the connected Hermes version (newer-than-supported surfaces show a "dashboard required" banner instead of breaking), a reorderable/hideable Browse sidebar shared between desktop and the iPhone Browse sheet, full-CRUD Kanban wired to the Hermes kanban plugin, and a one-window-per-server multi-profile model.

**Honest framing:** the official **Hermes Desktop** (Nous Research, Electron) leads on raw breadth — voice mode, image generation, a preview rail and file browser, 300+ models via the Nous Portal, and Windows/Linux builds — and **Scarf** is the broadest *native-Mac* feature set today (Hermes Proxy, credential pools, webhooks, quick commands). Talaria trades that breadth for focus, a clean integration contract, first-class SSH remoting (including a full-surface iOS), and the most complete distribution workflow.

## Screenshots

<p align="center">
  <img src="docs/screenshots/macos.png" alt="Talaria on macOS — Sessions browser connected to a remote Hermes server over SSH" height="380">
  <img src="docs/screenshots/ipados.png" alt="Talaria on iPadOS — Sessions browser" height="380">
</p>

<p align="center"><em>macOS (left) and iPadOS (right) — the Sessions browser, connected to a remote Hermes server over SSH. The iPad build reaches Hermes over the pure-Swift NIO-SSH tunnel.</em></p>

More macOS surfaces — live chat, model assignment, skills, and scheduled jobs:

<p align="center">
  <img src="docs/screenshots/chat.png" alt="Read-only chat transcript with user, thinking, and assistant turns" width="49%">
  <img src="docs/screenshots/models.png" alt="Models screen — main and auxiliary model assignment" width="49%">
</p>
<p align="center">
  <img src="docs/screenshots/skills.png" alt="Skills screen — per-skill enable toggles grouped by category" width="49%">
  <img src="docs/screenshots/cron.png" alt="Cron screen — scheduled jobs with schedule and prompt" width="49%">
</p>

<p align="center"><em>Chat, Models, Skills, and Cron.</em></p>

## Install

Download the latest signed DMG from the [Releases page](https://github.com/thirteen37/talaria/releases), drag `Talaria.app` to `/Applications`, and launch it from Finder. Updates land via in-app **Talaria → Check for Updates…** (Sparkle).

Or install with Homebrew (no tap required):

```sh
brew install --cask https://raw.githubusercontent.com/thirteen37/talaria/main/Casks/talaria.rb
```

Talaria drives [Hermes Agent](https://github.com/NousResearch/hermes-agent). Install `hermes` separately, include the dashboard web extra (`pip install -U 'hermes-agent[web]'`), and point Talaria at it via the local profile.

## Current Status

This repository contains the dashboard-mode build:

- `Talaria`: SwiftUI app (macOS, with a shared iOS target) — gateway chat (`/api/ws`) plus dashboard-backed Browse surfaces: Sessions, **Skills, Tools, MCP, Plugins** (one tabbed destination — MCP servers include add/edit, enable, connection test, and a Nous-approved install catalog), Cron, Kanban, Gateway, Hermes profiles (clone/rename/delete plus **profile distributions** — install/update from git, view manifest, export/import a `.tar.gz`, author `distribution.yaml`, and publish to git), **Configuration** (the `config.yaml` editor and the `.env` Environment editor as two tabs), **Soul, Personalities & Memory** (the `SOUL.md`/personalities editor, the built-in `MEMORY.md`/`USER.md` editor, and — when Hindsight is the active memory provider — a read-only **Hindsight** browser that lists and semantically searches its vector store, talking to Hindsight's REST API directly), Models, and **System** (Doctor, Updates, and Logs as three tabs). Chats can also be opened as the real Hermes TUI in an embedded terminal (macOS). The Browse sidebar is reorderable and pages can be hidden; a Settings screen holds Server Profiles, Sidebar Order, and Notifications. Optional OS-level chat notifications (agent-finished / tool-approval) and Sparkle auto-update.
- `HermesKit`: Swift package for the JSON-RPC chat-event model, the gateway WebSocket + NIO-SSH transport, dashboard HTTP client/supervisor, CLI fallbacks, profile models, and capability gates.
- `docs`: architecture, security, release, integration coverage, dashboard API, and [profile distributions & the `distribution.yaml` schema](docs/profile-distributions.md).

## Prerequisite: Hermes Agent

Talaria is only a front-end; it requires a running [Hermes Agent](https://github.com/NousResearch/hermes-agent) to drive (see [Install](#install) for the `hermes-agent[web]` setup).

- Repository: https://github.com/NousResearch/hermes-agent
- Website/docs: https://hermes-agent.nousresearch.com/

Hermes is the source of truth for everything Talaria renders — when behavior is ambiguous, check Hermes:

- ACP behavior and live session protocol details.
- Dashboard HTTP behavior for sessions, logs, skills, cron jobs, and updates.
- CLI command surfaces that do not have dashboard routes yet: `hermes sessions rename`, `hermes tools enable/disable`, `hermes doctor`, the Skills Hub mutations `hermes skills install/update/uninstall` (Skills Hub *search* reads the public Nous index over HTTP instead), and the profile-distribution commands `hermes profile install/update/info/export/import` (with `distribution.yaml` authored directly and git publish run on the host).
- Version and capability gates for features that land after the MVP baseline.

## Development

Run the package tests:

```sh
swift test --package-path HermesKit
```

Build the macOS app without code signing:

```sh
xcodebuild build \
  -project Talaria.xcodeproj \
  -scheme Talaria \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Build the shared package for iOS Simulator:

```sh
xcodebuild build \
  -scheme HermesKit \
  -destination 'generic/platform=iOS Simulator' \
  -workspace Talaria.xcworkspace
```

## License

Talaria is released under the [MIT License](LICENSE).

Third-party notices: [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
