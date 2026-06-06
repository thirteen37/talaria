# Security

Talaria must spawn `hermes dashboard`, `hermes doctor`, `hermes tools`, `hermes sessions rename`, `hermes chat --tui` (embedded terminal sessions), and `ssh` for remote profiles, so the Mac App Sandbox is not part of the v1 distribution model. Hardened Runtime, Developer-ID signing, and notarisation are still required for release artifacts.

## Entitlements

`Talaria/Talaria.entitlements` is the canonical entitlements file referenced by `CODE_SIGN_ENTITLEMENTS`. It explicitly disables the sandbox and pins the Hardened Runtime exception flags off (no JIT, no unsigned executable memory, no library validation bypass, no dyld env vars). Adding entitlements should be reviewed for blast radius — Talaria's threat model assumes the user trusts the binaries it launches because they configured the profile.

## Privacy manifest

`Talaria/PrivacyInfo.xcprivacy` declares the reportable API category the app actually touches:

- `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`) — `RecentServers` persists open-profile history.

No tracking, no third-party SDKs, no data collected from the user.

## Rules

- Do not store SSH passphrases. macOS remote dashboard startup and CLI fallbacks delegate authentication to the system `ssh` binary, ssh-agent, and `~/.ssh/config`.
- Do not write Hermes SQLite files directly.
- **Reading the Hermes `.env` to enumerate custom env vars is a deliberate, documented exception to the dashboard-API-only rule.** The Environment screen reads the `.env` file directly — locally via the filesystem, or on a remote profile via the same SSH `exec cat` transport (`RemoteSnapshotTransfer`) snapshots use — purely to *list* user-named keys the dashboard's `GET /api/env` doesn't know about. The path is resolved via `hermes config env-path` (the profile-scoped admin runner). All env **mutations** (set/update/delete) and full-value **reveal** still go through the dashboard API (`PUT`/`DELETE`/`POST /api/env/reveal`); plaintext read from the file is used only to compute a redacted preview and is not retained.
- **Editing the built-in memory files (`MEMORY.md` / `USER.md`) reads *and writes* them directly — the only direct-write exception, and the first non-dashboard remote write.** Hermes exposes no dashboard route for the raw text of these files (only `GET /api/memory` provider status + sizes), so the Memory editor reads and writes them on disk: locally via the filesystem, or on a remote profile through the same SSH transport as snapshots/`.env`, now extended with an `upload` that streams the file to a remote temp and atomically renames it over the target (`cat > tmp && mv -f tmp dest`, or sftp `put`+`rename`). **This adds no new trust surface:** the write reuses the exact SSH auth and TOFU host-key delegates as the read path — same `HostKeyStore`/pinned-key policy, same credential providers. Writes are advisory: the Hermes agent owns these files via its `memory` tool and may overwrite the user's edits (or vice versa), so the editor re-reads before writing and confirms before clobbering an out-of-band change. All routing goes through the unified `HermesFileStore`; the memory **provider picker** still uses the dashboard API (`PUT /api/memory/provider`).
- Keep profile secrets out of `profiles.json`; use Keychain only when a future feature needs stored tokens.
- Prefer explicit executable paths captured during profile probing to avoid shell PATH surprises.
- Log protocol frames only at debug level and avoid logging credential material.
- **Embedded TUI sessions always use system `ssh -tt` for remote profiles**, even when `HermesKit.useNIOSSHTransport` is enabled (the NIO path cannot drive a local-process PTY). They therefore follow the system-ssh trust model — ssh-agent, `~/.ssh/config`, and `~/.ssh/known_hosts` — *not* HermesKit's `HostKeyStore`/pinned-store path. A remote TUI launch can trigger a `known_hosts` prompt inside the embedded terminal on first connect; it does not go through the in-app TOFU confirm sheet. `BatchMode=yes` is set so a missing/locked key fails fast in the terminal rather than hanging on an interactive auth prompt.

## Key material and host-key trust on iOS

When `HermesKit.useNIOSSHTransport` is enabled (mandatory on iOS, opt-in on macOS), HermesKit reaches the remote dashboard — and the live-chat `/api/ws` gateway that rides it — over a pure-Swift SSH client (`swift-nio-ssh`) instead of the system `ssh` binary. On macOS without the opt-in, the remote dashboard uses a system `ssh -L` forward instead; on iOS, dashboard HTTP and the chat WebSocket both run through the NIO-SSH `direct-tcpip` tunnel owned by the window. Consequence: on macOS with the flag enabled, host-key trust can be evaluated by both system-ssh and HermesKit's ``HostKeyStore`` depending on the surface (TUI sessions always use system `ssh -tt`, while the dashboard/snapshot/admin paths use NIO-SSH). They can disagree on first connect, so UI must surface the exact transport error instead of silently retrying through a different path.

This path has materially different trust semantics that callers must honor:

- **Key material.** `FileIdentityProvider` reads `profile.identityFile` from disk and decodes the OpenSSH-format private key. `KeychainIdentityProvider` is the cross-platform alternative keyed by `ServerProfile.keychainKeyReference`; the actual Keychain wiring lands with the iOS app target.
- **Encrypted keys (v1 gap).** The in-tree OpenSSH key parser does not yet implement the bcrypt-KDF + aes256-ctr decryption path. Encrypted keys raise `SSHTransportError.needsPassphrase(keyPath:)`; re-invoking the transport factory with a passphrase will *not* unlock the key in this release. The documented workaround is to decrypt the key once offline with `ssh-keygen -p -m OPENSSH -f <keyPath> -N ''` and re-add it to the profile, or to stay on the system-ssh transport on macOS. Implementing in-process decryption is tracked as a follow-up.
- **No ssh-agent, no `~/.ssh/config`.** The NIO path does not consult either. Profiles that depend on agent forwarding or per-host config blocks must stay on the system-ssh transport (macOS only). This is a known v1 regression versus system-ssh.
- **Host-key trust.** On macOS the NIO transport layers `KnownHostsFileStore` (read-only, parses `~/.ssh/known_hosts`) over `PinnedHostKeyStore` (JSON file at `~/Library/Application Support/Talaria/known_hosts.json`). On iOS only the pinned store exists. On a first connect to a host that neither store recognizes, the transport raises `SSHTransportError.hostKeyUnknown(fingerprint:)` carrying the SHA256 fingerprint; the host app must present a TOFU confirm sheet and, on confirm, call `PinnedHostKeyStore.pin(...)` before retrying. Mismatches against a pinned key raise `.hostKeyMismatch(presented:pinned:)` and are never silently re-pinned. An `@revoked` entry in `~/.ssh/known_hosts` whose key matches the presented key raises `.hostKeyRevoked(fingerprint:)`; the host app must refuse the connection without offering a re-pin path, mirroring `/usr/bin/ssh`. Revocation overrides any pin in the JSON store — `CompositeHostKeyStore` short-circuits before evaluating other readers' decisions. `@cert-authority` entries are parsed but not honored as plain host-key matches in v1 (no CA chain verification yet).
- **Background sessions.** Long-lived SSH sessions die when an iOS app backgrounds. The iOS app target needs an explicit reconnect strategy for the NIO-SSH connection that carries the dashboard HTTP and the live-chat `/api/ws` gateway.
