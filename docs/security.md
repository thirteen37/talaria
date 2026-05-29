# Security

Talaria must spawn `hermes dashboard`, `hermes doctor`, `hermes tools`, `hermes sessions rename`, and `ssh` for remote profiles, so the Mac App Sandbox is not part of the v1 distribution model. Hardened Runtime, Developer-ID signing, and notarisation are still required for release artifacts.

## Entitlements

`Talaria/Talaria.entitlements` is the canonical entitlements file referenced by `CODE_SIGN_ENTITLEMENTS`. It explicitly disables the sandbox and pins the Hardened Runtime exception flags off (no JIT, no unsigned executable memory, no library validation bypass, no dyld env vars). Adding entitlements should be reviewed for blast radius — Talaria's threat model assumes the user trusts the binaries it launches because they configured the profile.

## Privacy manifest

`Talaria/PrivacyInfo.xcprivacy` declares the reportable API category the app actually touches:

- `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`) — `RecentServers` persists open-profile history.

No tracking, no third-party SDKs, no data collected from the user.

## Rules

- Do not store SSH passphrases. macOS remote dashboard startup and CLI fallbacks delegate authentication to the system `ssh` binary, ssh-agent, and `~/.ssh/config`.
- Do not write Hermes SQLite files directly.
- Keep profile secrets out of `profiles.json`; use Keychain only when a future feature needs stored tokens.
- Prefer explicit executable paths captured during profile probing to avoid shell PATH surprises.
- Log protocol frames only at debug level and avoid logging credential material.

## Key material and host-key trust on iOS

When `HermesKit.useNIOSSHTransport` is enabled (mandatory on iOS, opt-in on macOS), HermesKit uses a pure-Swift SSH client (`swift-nio-ssh`) instead of the system `ssh` binary for the ACP transport. Dashboard mode still uses system `ssh -L` on macOS, and iOS dashboard mode is deferred until NIO-based port forwarding exists. Consequence: on macOS with the flag enabled, host-key trust can be evaluated by both system-ssh and HermesKit's ``HostKeyStore`` depending on the surface. They can disagree on first connect, so UI must surface the exact transport error instead of silently retrying through a different path.

This path has materially different trust semantics that callers must honor:

- **Key material.** `FileIdentityProvider` reads `profile.identityFile` from disk and decodes the OpenSSH-format private key. `KeychainIdentityProvider` is the cross-platform alternative keyed by `ServerProfile.keychainKeyReference`; the actual Keychain wiring lands with the iOS app target.
- **Encrypted keys (v1 gap).** The in-tree OpenSSH key parser does not yet implement the bcrypt-KDF + aes256-ctr decryption path. Encrypted keys raise `SSHTransportError.needsPassphrase(keyPath:)`; re-invoking the transport factory with a passphrase will *not* unlock the key in this release. The documented workaround is to decrypt the key once offline with `ssh-keygen -p -m OPENSSH -f <keyPath> -N ''` and re-add it to the profile, or to stay on the system-ssh transport on macOS. Implementing in-process decryption is tracked as a follow-up.
- **No ssh-agent, no `~/.ssh/config`.** The NIO path does not consult either. Profiles that depend on agent forwarding or per-host config blocks must stay on the system-ssh transport (macOS only). This is a known v1 regression versus system-ssh.
- **Host-key trust.** On macOS the NIO transport layers `KnownHostsFileStore` (read-only, parses `~/.ssh/known_hosts`) over `PinnedHostKeyStore` (JSON file at `~/Library/Application Support/Talaria/known_hosts.json`). On iOS only the pinned store exists. On a first connect to a host that neither store recognizes, the transport raises `SSHTransportError.hostKeyUnknown(fingerprint:)` carrying the SHA256 fingerprint; the host app must present a TOFU confirm sheet and, on confirm, call `PinnedHostKeyStore.pin(...)` before retrying. Mismatches against a pinned key raise `.hostKeyMismatch(presented:pinned:)` and are never silently re-pinned. An `@revoked` entry in `~/.ssh/known_hosts` whose key matches the presented key raises `.hostKeyRevoked(fingerprint:)`; the host app must refuse the connection without offering a re-pin path, mirroring `/usr/bin/ssh`. Revocation overrides any pin in the JSON store — `CompositeHostKeyStore` short-circuits before evaluating other readers' decisions. `@cert-authority` entries are parsed but not honored as plain host-key matches in v1 (no CA chain verification yet).
- **Background sessions.** Long-lived SSH sessions die when an iOS app backgrounds. Out of scope for the transport sprint; the iOS app target needs an explicit reconnect strategy when it lands.
