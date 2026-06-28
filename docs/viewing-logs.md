# Viewing app logs

Talaria emits structured `os.Logger` entries under the `com.talaria.*` subsystem
family:

- `com.talaria.app` — app-side loggers (`AppLog`).
- `com.talaria.hermeskit` — shared package loggers (`HermesLog`): `transport`,
  `session`, `snapshot`, `dashboard`, and `gateway` categories. The dashboard
  stderr stream is mirrored into `HermesLog.dashboard`.

These feed **macOS Console.app** and **sysdiagnose**, which is where you read
them. (This replaces the former in-app "App Logs" tab, which read the process's
own `OSLogStore` back out — that store reliably persists only
`.notice`/`.error`/`.fault`: `.debug` is memory-only and `.info` is
quota-limited and frequently evicted, so the tab silently dropped exactly the
diagnostic lines Talaria logs most heavily. Console.app **live streaming**
delivers `.debug`/`.info` regardless of persistence, so for an attached device it
is a strict superset of what the tab showed. A *default* sysdiagnose reads the
same persisted store the old reader did, so it shares those gaps — the logging
configuration profile below closes them. See the persistence caveat under
[No Mac / TestFlight field build](#no-mac--testflight-field-build).)

> The separate **Logs** tab (Browse → System → Logs) is unrelated — it polls the
> Hermes dashboard's `/api/logs` route and stays. This doc is about the app's own
> `os.Logger` output.

## Device attached to a Mac

1. Open **Console.app** (`/Applications/Utilities/Console.app`).
2. Select the device (or `This Mac`) in the sidebar.
3. In the search field, filter `subsystem:com.talaria`.
4. Enable **Action → Include Info Messages** and **Action → Include Debug
   Messages** — without these, Console hides the `.info`/`.debug` lines (gateway
   turn-end, dashboard spawn command, etc.) the old in-app tab also dropped.
5. Press **Start streaming** and reproduce the issue.

Equivalent from the command line:

```sh
# Stream live, including debug-level lines (BEGINSWITH matches both
# com.talaria.app and com.talaria.hermeskit; the CLI predicate's `==` is exact):
log stream --predicate 'subsystem BEGINSWITH "com.talaria"' --level debug

# A USB-attached iPhone/iPad (libimobiledevice):
idevicesyslog
```

## No Mac / TestFlight field build

TestFlight surfaces only crash reports, not live logs, so a field tester captures
a **sysdiagnose** instead:

1. On the device, trigger a sysdiagnose: **hold both volume buttons + the side
   button** for ~1.5 s (a brief tap — not the power-off hold). The device
   vibrates; the archive is generated in the background after a minute or two.
2. Retrieve it from **Settings → Privacy & Security → Analytics & Improvements →
   Analytics Data**, scroll to a `sysdiagnose_…` entry, open it, and share it
   (AirDrop / Files / Mail).
3. On a Mac, expand the archive and open `system_logs.logarchive` in
   **Console.app**. Filter `subsystem:com.talaria` and enable Info/Debug messages
   as above.

### Persistence caveat

By default a sysdiagnose retains `.notice`/`.error`/`.fault` for the
`com.talaria` subsystem but **not** `.debug` (memory-only) and only a
quota-limited slice of `.info`. So a field sysdiagnose can still miss the
heavily-logged diagnostic lines.

### Optional: a logging configuration profile

To make no-Mac capture genuinely complete, install a logging configuration
profile that raises the persistence level for the `com.talaria` subsystems
before reproducing. A `.mobileconfig` with a `com.apple.system.logging` payload:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>com.apple.system.logging</string>
      <key>PayloadIdentifier</key>
      <string>com.talaria.logging</string>
      <key>PayloadUUID</key>
      <string>2B5F0E2C-0000-0000-0000-000000000001</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>Subsystems</key>
      <dict>
        <key>com.talaria.app</key>
        <dict>
          <key>DEFAULT-OPTIONS</key>
          <dict>
            <key>Level</key>
            <dict>
              <key>Enable</key>
              <string>Debug</string>
              <key>Persist</key>
              <string>Debug</string>
            </dict>
          </dict>
        </dict>
        <key>com.talaria.hermeskit</key>
        <dict>
          <key>DEFAULT-OPTIONS</key>
          <dict>
            <key>Level</key>
            <dict>
              <key>Enable</key>
              <string>Debug</string>
              <key>Persist</key>
              <string>Debug</string>
            </dict>
          </dict>
        </dict>
      </dict>
    </dict>
  </array>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadIdentifier</key>
  <string>com.talaria.logging.profile</string>
  <key>PayloadUUID</key>
  <string>2B5F0E2C-0000-0000-0000-000000000000</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadDisplayName</key>
  <string>Talaria verbose logging</string>
</dict>
</plist>
```

**Install:** AirDrop/email the `.mobileconfig` to the device, then **Settings →
General → VPN & Device Management → (Downloaded Profile) → Install**.
**Remove:** the same screen → the profile → **Remove Profile** (do this once
debugging is done — verbose persistence costs storage and battery). With the
profile installed, `.info`/`.debug` lines for `com.talaria` are retained in a
subsequent sysdiagnose.
