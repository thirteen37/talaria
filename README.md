# Talaria

Talaria is a native macOS front-end for Hermes Agent. The app is built with SwiftUI, with shared protocol and transport code in the `HermesKit` Swift package so the core can stay portable for a future iOS companion.

## Current Status

This repository currently contains the Sprint 0 scaffold:

- `Talaria`: macOS SwiftUI app shell.
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
- Remote support uses system SSH and explicit snapshot refresh semantics.
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
