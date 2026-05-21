# Manual Test Plan

Run this script before a v1 release candidate.

1. Create a local profile and verify `hermes --version`.
2. Start a local chat session and send a prompt.
3. Confirm streamed text, reasoning, and tool-call cards render.
4. Trigger and answer a permission prompt.
5. Interrupt a running session.
6. Resume the same session from the sessions browser.
7. Rename and delete a session through the app.
8. Run `hermes doctor` and copy the debug bundle.
9. Toggle a skill and a tool, then confirm the snapshot invalidates.
10. Create, edit, pause, resume, run, and delete a cron job.
11. Open an SSH profile, refresh the remote SQLite snapshot, and confirm the snapshot age badge updates.
12. Run `hermes update --check`.
