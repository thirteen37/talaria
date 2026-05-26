# Manual Test Plan

Run this script before a v1 release candidate.

1. Create a local profile and verify `hermes --version`.
2. Start a local chat session and send a prompt.
3. Confirm streamed text, reasoning, and tool-call cards render.
4. Trigger and answer a permission prompt.
5. Interrupt a running session.
6. Resume the same session from the sessions browser.
7. Rename and delete a session through the app.
8. **Doctor view**: open Manage → Doctor, click *Run Doctor*. Confirm:
   - Output renders in collapsible sections (headers recognised: `== Title ==`, `--- Title ---`, ALL-CAPS standalone titles).
   - Exit code is displayed next to the title bar.
   - *Copy bundle* puts raw report + Talaria version + profile summary on the clipboard.
9. **Skills view**: open Manage → Skills. Confirm:
   - Rows from `hermes skills list` render in the table with name, enabled toggle, path.
   - Toggling a skill flips the enabled state on the next refresh.
   - Selecting a row populates the right-hand markdown preview with `hermes skills show <name>`.
10. **Tools view**: open Manage → Tools. Confirm:
    - Rows from `hermes tools list` render with name, platform, enabled toggle.
    - Toggling persists across a manual *Refresh*.
11. **Cron view**: open Manage → Cron. Confirm:
    - `hermes cron list` rows appear left, editor right.
    - *Add* creates a job; editor saves a change; *Pause/Resume* toggle works; *Run Now* succeeds; *Delete* removes the row.
    - If `hermes cron add/update/delete` returns `unknown command`, the banner reads "Cron CRUD unavailable in this Hermes version." and no `jobs.json` side-write occurs.
12. **Logs view**: open Manage → Logs. Confirm:
    - With another chat turn running in a different window, lines arrive live.
    - Level + component filters narrow the view.
    - *Pause* halts the stream; resuming continues from the live tail.
    - Closing the view terminates the underlying child process — verify with `ps` that no orphan `tail -F` (remote) or polling task (local) lingers.
13. **Updates view**: open Manage → Updates. Confirm:
    - Banner reflects `hermes update --check` (gray = up to date, accent = available).
    - *Install update* streams progress lines into the scrolling log and ends with the exit-code summary.
    - Button is disabled when no update is available.
14. **Snapshot invalidation**: with a remote profile open, toggle a skill/tool (admin write) and confirm the SSH snapshot age badge does **not** refresh (skills/tools writes don't touch `state.db`); rename or delete a session and confirm the badge resets.
15. Open an SSH profile, refresh the remote SQLite snapshot, and confirm the snapshot age badge updates. Repeat steps 8–13 against the remote profile and confirm `SSHTransport.classifyStderr` surfaces "Permission denied" / "Connection timed out" correctly when the host is misconfigured.

## Release artifact verification

Run these against the signed, notarised, stapled build produced by `scripts/release.sh` — **not** a `CODE_SIGNING_ALLOWED=NO` dev build.

16. **Signing assertions** (in a shell):
    - `codesign --verify --deep --strict --verbose=2 build/export/Talaria.app` exits 0.
    - `xcrun stapler validate build/export/Talaria.app` reports `The validate action worked!`.
    - `xcrun stapler validate build/Talaria-<VERSION>.dmg` reports the same.
    - `spctl -a -vvv -t install build/export/Talaria.app` reports `accepted source=Notarized Developer ID`.
17. **Gatekeeper first-launch** (on a fresh Mac or a fresh user account):
    - Download the DMG from the GitHub Release page **via the browser** (not `curl` — Gatekeeper relies on the download quarantine xattr).
    - Drag `Talaria.app` to `/Applications`.
    - Launch from Finder (double-click). Confirm no quarantine warning appears.
18. **Sparkle in-app update** (only if the previous signed build is available):
    - Install the previous signed build, launch it once so Sparkle stores its profile.
    - Replace `docs/appcast.xml` to point at the new version.
    - Re-launch the older build. Confirm Sparkle finds the new release, downloads it, validates the ed25519 signature, and relaunches into the new build.
    - Trigger manually via **Talaria → Check for Updates…** and confirm the menu item is reachable.
19. **Version display**: the macOS About panel shows the `MARKETING_VERSION` and build number from `Info.plist`.
