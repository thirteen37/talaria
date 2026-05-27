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

Remote state is read from a snapshot created with `sqlite3 .backup` and fetched through one of two interchangeable transfer implementations:

- `SFTPSubprocessTransfer` (macOS default) shells out to `/usr/bin/sftp` and is byte-identical to the original v1 path.
- `NIOSSHCatTransfer` (opt-in on macOS via `HermesKit.useNIOSSHTransport`, mandatory on iOS) runs `cat -- '<remotePath>'` over a fresh `swift-nio-ssh` connection. Integrity is covered by SSH MACs on the wire plus the downstream SQLite `PRAGMA integrity_check`; a 256 MiB cap rejects misconfigured remote paths.

The `HermesKit.useNIOSSHTransport` flag only routes the **ACP transport** and the snapshot **fetch** through NIO. The snapshot **backup** (`ssh ... sqlite3 .backup`) and **cleanup** (`ssh ... rm -f`) steps in `RemoteSnapshot` still shell out to `/usr/bin/ssh` on macOS regardless of the flag, because the NIO-`exec` command runner that would replace them is deferred to the iOS app target sprint. The UI must surface snapshot age wherever remote SQLite data is displayed.

## Window Model

Each app window is scoped to one `ServerProfile`. The window owns its session clients, admin runner, database snapshot, version cache, and capability table.
