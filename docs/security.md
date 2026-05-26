# Security

Talaria must spawn `hermes`, `ssh`, `sqlite3`, `sftp`, and log-tail commands, so the Mac App Sandbox is not part of the v1 distribution model. Hardened Runtime, Developer-ID signing, and notarisation are still required for release artifacts.

## Entitlements

`Talaria/Talaria.entitlements` is the canonical entitlements file referenced by `CODE_SIGN_ENTITLEMENTS`. It explicitly disables the sandbox and pins the Hardened Runtime exception flags off (no JIT, no unsigned executable memory, no library validation bypass, no dyld env vars). Adding entitlements should be reviewed for blast radius — Talaria's threat model assumes the user trusts the binaries it launches because they configured the profile.

## Privacy manifest

`Talaria/PrivacyInfo.xcprivacy` declares the two reportable API categories the app actually touches:

- `NSPrivacyAccessedAPICategoryFileTimestamp` (reason `C617.1`) — reading `state.db` mtime for snapshot age display.
- `NSPrivacyAccessedAPICategoryUserDefaults` (reason `CA92.1`) — `RecentServers` persists open-profile history.

No tracking, no third-party SDKs, no data collected from the user.

## Rules

- Do not store SSH passphrases. SSH authentication is delegated to the system `ssh` binary, ssh-agent, and `~/.ssh/config`.
- Do not write Hermes SQLite files directly.
- Keep profile secrets out of `profiles.json`; use Keychain only when a future feature needs stored tokens.
- Prefer explicit executable paths captured during profile probing to avoid shell PATH surprises.
- Log protocol frames only at debug level and avoid logging credential material.
