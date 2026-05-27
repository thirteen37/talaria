# Talaria

Talaria is a native macOS front-end for Hermes Agent. The app is built with SwiftUI, with shared protocol and transport code in the `HermesKit` Swift package so the core can stay portable for a future iOS companion.

## Install

Download the latest signed DMG from the [Releases page](https://github.com/thirteen37/talaria/releases), drag `Talaria.app` to `/Applications`, and launch it from Finder. Updates land via in-app **Talaria → Check for Updates…** (Sparkle).

Talaria drives the [Hermes Agent](https://github.com/NousResearch/hermes-agent) CLI — install `hermes` separately and point Talaria at it via the local profile.

## Current Status

This repository contains the Sprint 6 (v1.0) build:

- `Talaria`: macOS SwiftUI app — chat, sessions, profiles, six Manage surfaces (Skills / Tools / Cron / Logs / Doctor / Updates), Sparkle auto-update.
- `HermesKit`: Swift package for ACP/JSON-RPC, transports, client/admin scaffolding, profile models, and capability gates.
- `docs`: architecture, security, release, ACP coverage, roadmap, and manual test-plan notes.

## References

### Hermes Agent Source Code

- Repository: https://github.com/NousResearch/hermes-agent
- Website/docs: https://hermes-agent.nousresearch.com/

Hermes Agent is the runtime Talaria targets. Talaria should treat Hermes as the source of truth for:

- ACP behavior and live session protocol details.
- CLI command surfaces such as `hermes doctor`, `hermes update`, `hermes skills`, `hermes tools`, and cron management.
- On-disk state layout under `HERMES_HOME`, especially read-only SQLite session data.
- Version and capability gates for features that land after the MVP baseline.

### Scarf

- Repository: https://github.com/awizemann/scarf

Scarf is a reference for product shape and information architecture, not an implementation model. Talaria borrows useful workflow ideas from Scarf while keeping a stricter implementation boundary:

- Native SwiftUI rendering over Hermes ACP instead of TUI embedding as the primary surface.
- SQLite reads are read-only; writes go through ACP or Hermes CLI commands.
- Remote support uses either the system SSH binary (macOS default) or a pure-Swift NIO-SSH transport (opt-in on macOS via the `HermesKit.useNIOSSHTransport` defaults key, mandatory on iOS), with explicit snapshot refresh semantics either way. The flag covers the ACP transport and the snapshot fetch only — backup/cleanup commands still use system-ssh on macOS until the future NIO-`exec` runner lands.
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
