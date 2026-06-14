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
9. **Skills view**: open Manage → **Skills, Tools, MCP, Plugins** and select the *Skills* tab. It's a
   master/detail split (resizable on macOS): a summary list on the left, a detail panel on the right.
   Confirm:
   - List rows show name, a Hub/Local pill, an "update available" hint, the category, a one-line
     description preview, and the enabled toggle; toggling flips the enabled state on the next refresh.
   - Selecting a row opens the detail panel: full description, a kind-appropriate action cluster, and a
     **Preview** section showing the skill's `SKILL.md` source with YAML-frontmatter + markdown syntax
     highlighting. (The preview resolves the real directory by frontmatter name, so a skill whose
     `name` differs from its folder — e.g. `creative-ideation` named `ideation` — still previews.)
   - **Search the Skills Hub**: expand the section, search (e.g. `git`); results show full
     name · source · trust + description. (Works without a live Hermes — plain HTTP.)
   - **Install** a small official skill from a search result, or paste an `official/…` id into
     **Install from identifier / URL** → green confirmation + the row appears.
   - **Hub** skill detail → **Update**, **Audit** (shows a report sheet), **Remove** (confirms, then
     clean-uninstalls), and **Force remove**; flags "Update available" when upstream is ahead.
   - **Built-in** skill detail → **Reset** (and **Repair** for official-trust skills) + **Force remove**.
   - **Local** skill detail → **Publish** (sheet: registry + repo + path) + **Force remove**.
   - **Force remove** (all kinds) → confirmation alert naming the on-disk path (and a re-seed warning
     for built-ins); it deletes the skill's directory and the row disappears after refresh. Verify the
     directory is gone on disk.
   - Toolbar **Bundled skills** menu → Opt out / Opt back in / Re-seed now (verify the
     `~/.hermes/skills/.no-bundled-skills` marker appears/disappears).
   - **Inactive built-in skills** (local **and** remote): if any built-in Hermes tracks in
     `~/.hermes/skills/.bundled_manifest` has its files **absent** from the active tree (deleted, or
     sitting only under `~/.hermes/skills/.archive/`), an **Inactive built-in skills** section lists
     them below the installed list. Listing is by on-disk presence (a host-shell `find`+`grep` scan),
     **not** dashboard-list membership — so a skill that's present but merely filtered out of the
     skills list (e.g. an `environments:`-scoped skill like the kanban skills, or a disabled one) is
     **not** shown, since Restore couldn't help it. Click **Restore** on a listed skill → it runs
     `hermes skills reset`; the row leaves the section and the skill reappears in the active list after
     refresh (verify its directory now exists under `~/.hermes/skills/<category>/`). Selecting a row
     opens the detail panel with its `SKILL.md` preview. The section is hidden when `.bundled_manifest`
     is absent or nothing is absent; Restore is disabled without an admin runner.
   - On a **remote (SSH)** profile: Audit/Reset/Repair/Publish/Force remove and the preview all work;
     clean **Remove** is disabled (its stdin confirm can't cross SSH) — use Force remove instead.
   - Point at a **< 0.15.1** Hermes (or simulate) → the lifecycle actions + Bundled-skills menu show
     the capability-warning banner rather than erroring.
10. **Tools view**: open Manage → **Skills, Tools, MCP, Plugins** and select the *Tools* tab. Confirm:
    - Rows from `hermes tools list` render with name, platform, enabled toggle.
    - Toggling persists across a manual *Refresh*.
11. **Cron view**: open Manage → Cron. Confirm:
    - Dashboard cron rows appear left, editor right.
    - *Add* creates a job; editor saves a change; *Pause/Resume* toggle works; *Run Now* succeeds; *Delete* removes the row.
    - Profiles below Hermes `0.14.0` show the dashboard-required banner instead of a broken editor.
12. **MCP Servers view**: open Manage → **Skills, Tools, MCP, Plugins** and select the *MCP Servers* tab. Confirm:
    - Configured servers list left (name, transport, address, enabled toggle); editor/detail right.
    - *Add* a stdio server (command + one-arg-per-line args + KEY=VALUE env) **and** a remote server (URL + auth) — both appear after refresh.
    - The enabled toggle persists; *Test* shows the tool list (or an error for an unreachable server); *Delete* clears the selection.
    - *Edit (re-create)* round-trips via delete+re-add: a previously-disabled server stays disabled, an argument containing a space survives, and secret env values must be re-entered to keep them (a server with a tool allowlist shows the can't-preserve warning).
    - *Catalog* lists Nous-approved entries; installing one (supplying any required env) adds a server.
    - Profiles below Hermes `0.15.1` show the dashboard-required banner instead of a broken editor.
13. **Logs view**: open Manage → **System** and select the *Logs* tab. Confirm:
    - With another chat turn running in a different window, polled dashboard log lines arrive.
    - Level + component filters narrow the view.
    - *Pause* halts polling; resuming continues from the latest tail window without duplicating old lines.
14. **Updates view**: open Manage → **System** and select the *Updates* tab. Confirm:
    - Banner reflects dashboard `/api/status` update state.
    - *Install update* starts the dashboard update action, polls action status, and appends only new log lines.
    - Button is disabled when no update is available.
15. **Config & Env view**: open Manage → **Config & Env**. Confirm it opens a two-tab view with the *Configuration* tab (the `config.yaml` editor) selected by default and an *Environment* tab beside it, and that "Environment" no longer appears as its own sidebar row. On the *Configuration* tab, confirm:
    - The toolbar profile picker lists profiles from the dashboard (`GET /api/profiles`) with clean names (no CLI table marker glyphs on `default`).
    - The structured form groups fields by category with type-appropriate controls (text, number + stepper, toggle, enum picker, list add/remove).
    - Edit a field and *Save*; reopen and confirm the value persisted and unrelated keys were left untouched.
    - Toggle **YAML**: the pane mirrors the edited config; an invalid edit shows an inline parse error and disables *Save*.
    - Pick a non-`default` profile and confirm it loads its own config (reached through the window's shared dashboard scoped via `?profile=<name>` — no separate dashboard spawns).
    - **Compare**: reveals a second profile picker and switches to the read-only diff; *Differences only* filters matching rows.
    - With the dashboard unreachable, the surface degrades to a read-only YAML view of the on-disk config and disables *Save*.
    - Switch to the *Environment* tab: rows from `GET /api/env` render with redacted previews; add/edit/delete a custom var (mutations go through `PUT`/`DELETE /api/env`); *Reveal* fetches the full value via `POST /api/env/reveal`. The detail title tracks the active tab.
16. **Cross-profile sync** (Profiles screen, **desktop + iPad**): clone the default profile to create a named profile (e.g. `work`). Open Manage → **Profiles** and select the **Sync** tab (beside the **Profiles** management tab). Pick a profile from the top picker, then use the **Skills / Config / Environment** segmented sections (each badge shows that section's diff count). Confirm:
    - The tab enumerates named profiles itself (a freshly cloned profile appears after toolbar *Refresh* without leaving the tab).
    - **Skills**: install a hub skill into *default* only, refresh, and confirm a "missing" row appears for `work`. Push it (per-row **Install** or **Sync all**); verify with `hermes -p work skills list` that it landed. A skill with no resolvable Skills Hub identifier shows a blocked caption ("Not in the Skills Hub catalog — install manually"). A Hub-outdated skill shows an **Update** button (no diff — "update available" is measured against the Hub, not default).
    - **Customized-skill drift**: edit an **unmanaged** (builtin/local) skill's `SKILL.md` in `work` so it differs from default's copy. Open the Skills section and confirm a brief "Checking customized skills…" then a **Customized (differs from default)** group listing that skill (marked *modified*). Select it: a read-only bottom panel shows the side-by-side line diff (default left, `work` right). Only unmanaged skills present in both profiles are read/diffed (Hub-managed skills are excluded); a skill whose `SKILL.md` can't be read on a side is silently skipped.
    - **Config** (two-column comparison, reused from the config editor): switch the model/provider in *default*'s config, open the Config section, and confirm the **default** (left) and **work** (right) columns differ, with the field label shown **once** per row above both columns (not duplicated). Hover a differing row and click the **→** copy arrow; confirm it pushes default's value into `work` **immediately** (no separate Save) and the named `config.yaml` got it while unrelated keys survived. Confirm there is **no ← (reverse) arrow** (one-way). *Differences only* is on by default.
    - **Environment** (two-column comparison): rotate a key in *default*'s `.env`, open the Environment section, and confirm the row shows `KEY` with **default** and **work** redacted values in two columns. The **eye** reveals each side's plaintext locally (no `POST /api/env/reveal` — it's already in memory) and re-masks on refresh. Click **→**; confirm it copies default's secret into `work` immediately via `PUT /api/env?profile=work` on the shared dashboard, and that **`work`'s `.env` actually changed** (`grep KEY $(hermes -p work config env-path)`) — the write must land in the profile's home, not the base. A managed-key rejection surfaces on the row.
    - **Extras** (keys/skills present only in the named profile) render display-only ("only in 'work' (not removed)") — v1 never deletes.
    - **Sync everything from default** presents a confirmation sheet enumerating the batch ("install 2 skills, push 3 config values, copy 2 credentials to 'work'") before writing, because it copies secrets; the per-row copy arrows act without a sheet.
    - **Base-runner regression**: switch the *window* to a named Hermes profile, reopen Profiles → Sync, and confirm the comparison's **source column is still `default`** (not the window's named profile).
    - **iPhone**: the same tab falls back to a stacked read-only-ish list (no two-column comparison) with per-profile sync actions.
    - On a Hermes below the dashboard/env pin (0.14.0), confirm the inline capability warning shows and pushes are gated.
17. **Memory view**: open Manage → **Soul, Personalities & Memory** and select the *Memory* tab. Confirm:
    - `MEMORY.md` and `USER.md` rows load with their content and a live char count; the provider line reads **Provider: Built-in** (or the provider name if an external one is active; **Unknown** with the dashboard down — editing still works).
    - Edit `MEMORY.md`, *Save* (⌘↩); reload (toolbar *Refresh*) and confirm it persisted on disk (`~/.hermes/memories/MEMORY.md`). Repeat for `USER.md`.
    - Type past the char cap and confirm the counter turns red with the over-budget note, but *Save* still writes.
    - **Unsaved-edits guard**: edit, then switch row (or tab) → confirm the Save/Discard/Cancel dialog.
    - **Overwrite detection**: with unsaved edits, change the file out-of-band on disk, then *Save* → confirm the "File changed on disk" overwrite prompt; *Overwrite* writes your version, *Cancel* keeps the file.
    - **External provider active**: set a memory provider in Plugins and confirm the "external provider active" warning appears on the editor.
18. **Dashboard lifecycle**: open two windows for the same profile and confirm they share one `hermes dashboard` process. Close both and verify the child exits.
    - **Reconnect**: with a dashboard connected, trigger **Reconnect** (window toolbar; or the banner button after a failed connect). Confirm the dashboard tears down and re-establishes (surfaces briefly show "connecting…" then recover). For a remote profile, simulate a wedge by killing the remote `hermes dashboard` (or dropping the link) so surfaces start erroring while still "connected", then Reconnect and confirm recovery without reopening the window. On iOS, the same control is in the nav bar (and the error banner).
    - **iOS/iPad background→foreground recovery**: with a live chat open mid-conversation, background the app and let the device sleep (or wait long enough for the SSH connection to drop), then reopen. Confirm a brief "Reconnecting…" banner, that the chat re-resumes with its history intact and accepts a new prompt, and that the transcript stays visible throughout. Then confirm a *brief* app-switch (flip away and back within ~2s) does **not** trigger a reconnect/teardown flash — a live connection is left untouched. If the chat was a brand-new session the gateway hadn't persisted, confirm it shows "Connection lost — start a new chat to continue." without blanking the transcript.
19. Set a fixed dashboard port in the profile editor, reopen the profile, and confirm `hermes dashboard` binds that port. Clear the field and confirm Talaria returns to automatic port allocation.
20. Open an SSH profile and repeat steps 8–17 against the remote profile. Confirm dashboard startup failures surface useful messages for missing `[web]`, auth failure, and connection timeout. For the cross-profile sync step specifically, confirm the named profiles' `config.yaml`/`.env` reads and the scoped-dashboard pushes work over both the system-`ssh` (macOS sftp) and NIO/iOS paths. For the Memory step specifically, confirm the **remote** Memory read/write works over both the system-`ssh` (macOS sftp) and NIO/iOS paths, that the file actually changed on the remote host, and that a named Hermes profile targets `profiles/<name>/memories/…`.
    - **Slow first launch after a Hermes update**: on a remote that has just been updated (so `hermes dashboard` recompiles the web UI), confirm the window shows a "Building web UI…" banner while it builds and then comes online — rather than failing at the base timeout. If it genuinely never serves, confirm the sidebar/`notReachable` message names the cause (last probe error / ssh channel error), and that the `dashboard` os_log category (System log console) carries the spawn command and probe detail.
21. **Terminal (TUI) sessions** (macOS):
    - **Local, new**: click the terminal button beside *New session*. Confirm the real Hermes TUI renders in the detail pane, accepts keystrokes, and that the tab shows a `terminal` glyph.
    - **Tab survival**: switch to another tab (or a Browse page) and back. Confirm the TUI process and scrollback survive (it is not relaunched).
    - **Close**: close the TUI tab (⌘W or the row close button) and confirm the `hermes` process exits (e.g. `pgrep -f 'chat --tui'` drops it). Repeat by closing the *window* with a TUI tab open — the process must also exit (no leak).
    - **Resume**: in Manage → Sessions, right-click a session → *Open as TUI*. Confirm it resumes that session (`-r <id>`).
    - **Conflict rule**: open a session inline (normal tap), then confirm *Open as TUI* is disabled for it; and that with a TUI tab open, tapping the same session in the browser focuses the existing TUI tab instead of starting a second chat.
    - **Relaunch overlay**: exit the TUI from inside (e.g. `/exit` or Ctrl-D). Confirm the "Session ended" overlay appears and *Relaunch* starts a fresh TUI in the same tab.
    - **SSH**: repeat the new/resume flows against an SSH profile. Confirm interactive keys work over `ssh -tt` and the remote TUI draws correctly (including, on a first connect, any `known_hosts` prompt shown inside the terminal).

22. **Notifications** (Settings → **Notifications**, macOS or iOS):
    - The master toggle defaults off. Flip it on and confirm the OS authorization prompt appears the first time; the two sub-toggles (*Agent finished*, *Tool approval*) default on.
    - With the toggles on, start a turn in a chat that is **not** the foreground+selected session (another tab, window, or backgrounded app) and confirm an "Agent finished responding." banner fires; trigger a tool-approval request and confirm its banner fires.
    - With that chat foreground **and** selected, confirm no banner fires (the watched chat is suppressed).
    - Tap a banner and confirm it focuses the originating profile window and selects the session.
    - Turn the master toggle off and confirm nothing notifies regardless of the sub-toggles.

## Release artifact verification

Run these against the signed, notarised, stapled build produced by `scripts/release.sh` — **not** a `CODE_SIGNING_ALLOWED=NO` dev build.

23. **Signing assertions** (in a shell):
    - `codesign --verify --deep --strict --verbose=2 build/export/Talaria.app` exits 0.
    - `xcrun stapler validate build/export/Talaria.app` reports `The validate action worked!`.
    - `xcrun stapler validate build/Talaria-<VERSION>.dmg` reports the same.
    - `spctl -a -vvv -t install build/export/Talaria.app` reports `accepted source=Notarized Developer ID`.
24. **Gatekeeper first-launch** (on a fresh Mac or a fresh user account):
    - Download the DMG from the GitHub Release page **via the browser** (not `curl` — Gatekeeper relies on the download quarantine xattr).
    - Drag `Talaria.app` to `/Applications`.
    - Launch from Finder (double-click). Confirm no quarantine warning appears.
25. **Sparkle in-app update** (only if the previous signed build is available):
    - Install the previous signed build, launch it once so Sparkle stores its profile.
    - Replace `docs/appcast.xml` to point at the new version.
    - Re-launch the older build. Confirm Sparkle finds the new release, downloads it, validates the ed25519 signature, and relaunches into the new build.
    - Trigger manually via **Talaria → Check for Updates…** and confirm the menu item is reachable.
26. **Version display**: the macOS About panel shows the `MARKETING_VERSION` and build number from `Info.plist`.
