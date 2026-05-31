# Talaria

Talaria is a native macOS front-end for Hermes Agent. The app is built with SwiftUI, with shared protocol and transport code in the `HermesKit` Swift package so the core can stay portable for a future iOS companion.

## Install

Download the latest signed DMG from the [Releases page](https://github.com/thirteen37/talaria/releases), drag `Talaria.app` to `/Applications`, and launch it from Finder. Updates land via in-app **Talaria → Check for Updates…** (Sparkle).

Talaria drives [Hermes Agent](https://github.com/NousResearch/hermes-agent). Install `hermes` separately, include the dashboard web extra (`pip install -U 'hermes-agent[web]'`), and point Talaria at it via the local profile.

## Current Status

This repository contains the Sprint 7 dashboard-mode build:

- `Talaria`: macOS SwiftUI app — ACP chat, dashboard-backed sessions, profiles, Manage surfaces (Skills / Tools / Cron / Logs / Doctor / Updates), Sparkle auto-update.
- `HermesKit`: Swift package for ACP/JSON-RPC, transports, dashboard HTTP client/supervisor, CLI fallbacks, profile models, and capability gates.
- `docs`: architecture, security, release, integration coverage, roadmap, and manual test-plan notes.

## References

### Hermes Agent Source Code

- Repository: https://github.com/NousResearch/hermes-agent
- Website/docs: https://hermes-agent.nousresearch.com/

Hermes Agent is the runtime Talaria targets. Talaria should treat Hermes as the source of truth for:

- ACP behavior and live session protocol details.
- Dashboard HTTP behavior for sessions, logs, skills, cron jobs, and updates.
- CLI command surfaces that do not have dashboard routes yet: `hermes sessions rename`, `hermes tools enable/disable`, and `hermes doctor`.
- Version and capability gates for features that land after the MVP baseline.

### Scarf

- Repository: https://github.com/awizemann/scarf

Scarf is a reference for product shape and information architecture, not an implementation model. Talaria borrows useful workflow ideas from Scarf while keeping a stricter implementation boundary:

- Native SwiftUI rendering over Hermes ACP instead of TUI embedding as the primary surface.
- Non-chat surfaces use `hermes dashboard` on loopback; Talaria does not read or write Hermes SQLite files directly.
- Remote support uses system SSH on macOS for ACP, dashboard port forwarding, and remaining CLI fallbacks. The pure-Swift NIO-SSH transport remains available for ACP experimentation and future iOS work.
- Release, signing, sandbox, and Sparkle constraints are documented before packaging work begins.

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
