# Security

Talaria must spawn `hermes`, `ssh`, `sqlite3`, `sftp`, and log-tail commands, so the Mac App Sandbox is not part of the v1 distribution model. Hardened Runtime, Developer-ID signing, and notarisation are still required for release artifacts.

## Rules

- Do not store SSH passphrases. SSH authentication is delegated to the system `ssh` binary, ssh-agent, and `~/.ssh/config`.
- Do not write Hermes SQLite files directly.
- Keep profile secrets out of `profiles.json`; use Keychain only when a future feature needs stored tokens.
- Prefer explicit executable paths captured during profile probing to avoid shell PATH surprises.
- Log protocol frames only at debug level and avoid logging credential material.
