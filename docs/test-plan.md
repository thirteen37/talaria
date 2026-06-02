# Manual Test Plan

Run this script before a v1 release candidate.

1. Create a local profile and verify `hermes --version`.
2. Start a local chat session and send a prompt.
3. Confirm streamed text, reasoning, and tool-call cards render.
4. Trigger and answer a permission prompt.
5. Interrupt a running session.
6. Resume the same session from the sessions browser.
7. Rename and delete a session through the app.
8. **Doctor view**: open Manage → **System** and select the *Doctor* tab, click *Run Doctor*. Confirm:
   - Prerequisite cards show Hermes `>= 0.14.0` and dashboard reachability.
   - Output renders in collapsible sections (headers recognised: `== Title ==`, `--- Title ---`, ALL-CAPS standalone titles).
   - Exit code is displayed next to the title bar.
   - *Copy bundle* puts raw report + Talaria version + profile summary on the clipboard.
9. **Skills view**: open Manage → Skills. Confirm:
   - Rows from the dashboard render in the table with name, enabled toggle, and path/source metadata.
   - Toggling a skill flips the enabled state on the next refresh.
   - **Search the Skills Hub**: expand the section, search (e.g. `git`); results show full
     name · source · trust + description. (Works without a live Hermes — plain HTTP.)
   - **Install** a small official skill from a search result → it appears in the table and toggles.
   - **Install from identifier / URL**: paste an `official/…` id → green confirmation + the row appears.
   - Select a hub-installed skill → detail pane offers **Update** and **Remove** (and flags
     "Update available" when upstream is ahead); **Remove** confirms, then deletes the skill.
   - A builtin/local (non-hub) skill shows **no** Update/Remove in its detail pane.
10. **Tools view**: open Manage → Tools. Confirm:
    - Rows from `hermes tools list` render with name, platform, enabled toggle.
    - Toggling persists across a manual *Refresh*.
11. **Cron view**: open Manage → Cron. Confirm:
    - Dashboard cron rows appear left, editor right.
    - *Add* creates a job; editor saves a change; *Pause/Resume* toggle works; *Run Now* succeeds; *Delete* removes the row.
    - Profiles below Hermes `0.14.0` show the dashboard-required banner instead of a broken editor.
12. **Logs view**: open Manage → **System** and select the *Logs* tab. Confirm:
    - With another chat turn running in a different window, polled dashboard log lines arrive.
    - Level + component filters narrow the view.
    - *Pause* halts polling; resuming continues from the latest tail window without duplicating old lines.
13. **Updates view**: open Manage → **System** and select the *Updates* tab. Confirm:
    - Banner reflects dashboard `/api/status` update state.
    - *Install update* starts the dashboard update action, polls action status, and appends only new log lines.
    - Button is disabled when no update is available.
14. **Configuration view**: open Manage → **Configuration**. Confirm it opens a two-tab view with the *Configuration* tab (the `config.yaml` editor) selected by default and an *Environment* tab beside it, and that "Environment" no longer appears as its own sidebar row. On the *Configuration* tab, confirm:
    - The toolbar profile picker lists profiles from the dashboard (`GET /api/profiles`) with clean names (no CLI table marker glyphs on `default`).
    - The structured form groups fields by category with type-appropriate controls (text, number + stepper, toggle, enum picker, list add/remove).
    - Edit a field and *Save*; reopen and confirm the value persisted and unrelated keys were left untouched.
    - Toggle **YAML**: the pane mirrors the edited config; an invalid edit shows an inline parse error and disables *Save*.
    - Pick a non-`default` profile and confirm it loads its own config (a profile-scoped `hermes -p <name> dashboard` spawns; closing the surface releases it).
    - **Compare**: reveals a second profile picker and switches to the read-only diff; *Differences only* filters matching rows.
    - With the dashboard unreachable, the surface degrades to a read-only YAML view of the on-disk config and disables *Save*.
    - Switch to the *Environment* tab: rows from `GET /api/env` render with redacted previews; add/edit/delete a custom var (mutations go through `PUT`/`DELETE /api/env`); *Reveal* fetches the full value via `POST /api/env/reveal`. The detail title tracks the active tab.
15. **Dashboard lifecycle**: open two windows for the same profile and confirm they share one `hermes dashboard` process. Close both and verify the child exits.
16. Set a fixed dashboard port in the profile editor, reopen the profile, and confirm `hermes dashboard` binds that port. Clear the field and confirm Talaria returns to automatic port allocation.
17. Open an SSH profile and repeat steps 8–14 against the remote profile. Confirm dashboard startup failures surface useful messages for missing `[web]`, auth failure, and connection timeout.
18. **Terminal (TUI) sessions** (macOS):
    - **Local, new**: click the terminal button beside *New session*. Confirm the real Hermes TUI renders in the detail pane, accepts keystrokes, and that the tab shows a `terminal` glyph.
    - **Tab survival**: switch to another tab (or a Browse page) and back. Confirm the TUI process and scrollback survive (it is not relaunched).
    - **Close**: close the TUI tab (⌘W or the row close button) and confirm the `hermes` process exits (e.g. `pgrep -f 'chat --tui'` drops it). Repeat by closing the *window* with a TUI tab open — the process must also exit (no leak).
    - **Resume**: in Manage → Sessions, right-click a session → *Open as TUI*. Confirm it resumes that session (`-r <id>`).
    - **Conflict rule**: open a session inline (normal tap), then confirm *Open as TUI* is disabled for it; and that with a TUI tab open, tapping the same session in the browser focuses the existing TUI tab instead of starting a second chat.
    - **Relaunch overlay**: exit the TUI from inside (e.g. `/exit` or Ctrl-D). Confirm the "Session ended" overlay appears and *Relaunch* starts a fresh TUI in the same tab.
    - **SSH**: repeat the new/resume flows against an SSH profile. Confirm interactive keys work over `ssh -tt` and the remote TUI draws correctly (including, on a first connect, any `known_hosts` prompt shown inside the terminal).

19. **Notifications** (Settings → **Notifications**, macOS or iOS):
    - The master toggle defaults off. Flip it on and confirm the OS authorization prompt appears the first time; the two sub-toggles (*Agent finished*, *Tool approval*) default on.
    - With the toggles on, start a turn in a chat that is **not** the foreground+selected session (another tab, window, or backgrounded app) and confirm an "Agent finished responding." banner fires; trigger a tool-approval request and confirm its banner fires.
    - With that chat foreground **and** selected, confirm no banner fires (the watched chat is suppressed).
    - Tap a banner and confirm it focuses the originating profile window and selects the session.
    - Turn the master toggle off and confirm nothing notifies regardless of the sub-toggles.

## Release artifact verification

Run these against the signed, notarised, stapled build produced by `scripts/release.sh` — **not** a `CODE_SIGNING_ALLOWED=NO` dev build.

20. **Signing assertions** (in a shell):
    - `codesign --verify --deep --strict --verbose=2 build/export/Talaria.app` exits 0.
    - `xcrun stapler validate build/export/Talaria.app` reports `The validate action worked!`.
    - `xcrun stapler validate build/Talaria-<VERSION>.dmg` reports the same.
    - `spctl -a -vvv -t install build/export/Talaria.app` reports `accepted source=Notarized Developer ID`.
21. **Gatekeeper first-launch** (on a fresh Mac or a fresh user account):
    - Download the DMG from the GitHub Release page **via the browser** (not `curl` — Gatekeeper relies on the download quarantine xattr).
    - Drag `Talaria.app` to `/Applications`.
    - Launch from Finder (double-click). Confirm no quarantine warning appears.
22. **Sparkle in-app update** (only if the previous signed build is available):
    - Install the previous signed build, launch it once so Sparkle stores its profile.
    - Replace `docs/appcast.xml` to point at the new version.
    - Re-launch the older build. Confirm Sparkle finds the new release, downloads it, validates the ed25519 signature, and relaunches into the new build.
    - Trigger manually via **Talaria → Check for Updates…** and confirm the menu item is reachable.
23. **Version display**: the macOS About panel shows the `MARKETING_VERSION` and build number from `Info.plist`.
