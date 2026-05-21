# Architecture

Talaria is a SwiftUI macOS app backed by a shared `HermesKit` Swift package. The app renders Hermes natively instead of embedding the TUI. Live sessions speak ACP over newline-delimited JSON-RPC frames.

## Core Packages

- `ACP`: Codable JSON-RPC and ACP schema types.
- `Transport`: bidirectional byte streams for local processes, SSH processes, and in-memory tests.
- `Client`: request correlation and session lifecycle orchestration.
- `Hermes`: CLI admin wrappers, read-only database access, version parsing, and capability gates.
- `Profiles`: local and SSH server profiles.

## Read And Write Model

Hermes state reads come from SQLite opened read-only. Writes go through ACP or the Hermes CLI only. The app never mutates Hermes database files directly.

Remote state is read from a snapshot created with `sqlite3 .backup` and fetched through the system SSH/SFTP tools. The UI must surface snapshot age wherever remote SQLite data is displayed.

## Window Model

Each app window is scoped to one `ServerProfile`. The window owns its session clients, admin runner, database snapshot, version cache, and capability table.
