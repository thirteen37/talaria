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
   - Prerequisite cards show Hermes `>= 0.14.0` and dashboard reachability.
   - Output renders in collapsible sections (headers recognised: `== Title ==`, `--- Title ---`, ALL-CAPS standalone titles).
   - Exit code is displayed next to the title bar.
   - *Copy bundle* puts raw report + Talaria version + profile summary on the clipboard.
9. **Skills view**: open Manage → Skills. Confirm:
   - Rows from the dashboard render in the table with name, enabled toggle, and path/source metadata.
   - Toggling a skill flips the enabled state on the next refresh.
10. **Tools view**: open Manage → Tools. Confirm:
    - Rows from `hermes tools list` render with name, platform, enabled toggle.
    - Toggling persists across a manual *Refresh*.
11. **Cron view**: open Manage → Cron. Confirm:
    - Dashboard cron rows appear left, editor right.
    - *Add* creates a job; editor saves a change; *Pause/Resume* toggle works; *Run Now* succeeds; *Delete* removes the row.
    - Profiles below Hermes `0.14.0` show the dashboard-required banner instead of a broken editor.
12. **Logs view**: open Manage → Logs. Confirm:
    - With another chat turn running in a different window, polled dashboard log lines arrive.
    - Level + component filters narrow the view.
    - *Pause* halts polling; resuming continues from the latest tail window without duplicating old lines.
13. **Updates view**: open Manage → Updates. Confirm:
    - Banner reflects dashboard `/api/status` update state.
    - *Install update* starts the dashboard update action, polls action status, and appends only new log lines.
    - Button is disabled when no update is available.
14. **Dashboard lifecycle**: open two windows for the same profile and confirm they share one `hermes dashboard` process. Close both and verify the child exits.
15. Open an SSH profile and repeat steps 8–13 against the remote profile. Confirm dashboard startup failures surface useful messages for missing `[web]`, auth failure, and connection timeout.

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
