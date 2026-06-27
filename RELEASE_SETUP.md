# Release setup checklist

Sprint 6 wired the full release pipeline (signing, notarisation, Sparkle,
GitHub Actions). The pipeline runs once you provide the per-developer values
below. Steps 1-4 are required before `scripts/release.sh` will succeed; the
rest unlock specific features.

## 1. Apple Developer team ID — DONE

`project.yml` ships with `DEVELOPMENT_TEAM: "9URLHJ84PY"` (extracted from your
existing Apple Development cert: `OU=9URLHJ84PY` in
`Apple Development: YU XI LIM`).

**Still required:** a **Developer ID Application** certificate. The cert in
your login keychain today is an "Apple Development" cert, which signs builds
for your own devices only. For Gatekeeper-acceptable distribution you need
the Developer ID Application variant.

1. [developer.apple.com → Certificates → Create](https://developer.apple.com/account/resources/certificates/add).
2. Choose **Developer ID Application**, follow the CSR flow.
3. Download the `.cer`, double-click to install in login keychain.
4. Verify: `security find-identity -v -p codesigning` should now list
   `"Developer ID Application: YU XI LIM (9URLHJ84PY)"`.

## 2. App Store Connect API key (for notarytool) — DONE

A working keychain profile named `TalariaNotary` is already registered on
this machine and authenticates against
`https://appstoreconnect.apple.com/notary/v2/submissions` (verified via
`xcrun notarytool history --keychain-profile TalariaNotary`).

`scripts/release.sh` reads `TALARIA_NOTARY_PROFILE` (default: `TalariaNotary`),
so no further local setup is needed.

If you ever need to re-register on another machine:

1. [appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **+** → name it "Talaria Notarization" → role **Developer**.
3. **Download the `.p8` file immediately** (one-time download). Store at
   `~/.private/AuthKey_<KEYID>.p8` (or another secure path outside git).
4. Note the **Key ID** (10 chars in the table) and **Issuer ID** (UUID at
   the top of the Keys page).
5. Register a notarytool keychain profile:
   ```sh
   xcrun notarytool store-credentials "TalariaNotary" \
     --key ~/.private/AuthKey_<KEYID>.p8 \
     --key-id <KEY_ID> \
     --issuer <ISSUER_ID>
   ```

For CI (GitHub Actions), the same `.p8`, Key ID, and Issuer ID still need
to be added as `ASC_API_KEY_BASE64`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`
secrets — see §4.

## 3. Sparkle ed25519 key pair — DONE

The keypair was generated during Sprint 6:
- **Public key** (`GIBPobenQOcE7P0JhqYaCCObUnscomo3On/yfONLHeU=`) committed
  to `Talaria/Info.plist:SUPublicEDKey`.
- **Private key** stored in the login Keychain (item
  `https://sparkle-project.org`).

To export the private key for the GitHub `SPARKLE_ED25519_PRIVATE_KEY`
secret (the `-x` flag writes the key as base64 to the path you specify;
`-p` would print the **public** key, which is the wrong direction):

```sh
SPARKLE_BIN=~/Library/Developer/Xcode/DerivedData/Talaria-*/SourcePackages/artifacts/sparkle/Sparkle/bin
$SPARKLE_BIN/generate_keys -x /tmp/sparkle_priv.key
pbcopy < /tmp/sparkle_priv.key
rm -P /tmp/sparkle_priv.key
```

**This is a long-lived signing key.** If it leaks, attackers can publish
updates that the app will trust; rotate immediately by generating a new
pair and shipping an update with the new public key.

If you ever need to regenerate from scratch (lost keychain entry, key
compromise), `generate_keys` with no args creates a fresh pair and
prints the new public key — paste that into `SUPublicEDKey` and ship a
release before the old key is considered trusted by any installed copies.

## 4. GitHub repo secrets (for `.github/workflows/release.yml`)

Set these in **Settings → Secrets and variables → Actions**:

| Secret | How to produce |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Export your Developer ID cert + key from Keychain Access as `.p12`, then `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set during `.p12` export |
| `KEYCHAIN_PASSWORD` | Any strong random string (e.g. `openssl rand -hex 32`) — only used for the temporary CI keychain |
| `ASC_API_KEY_BASE64` | `base64 -i ~/.private/AuthKey_<KEYID>.p8 \| pbcopy` |
| `ASC_API_KEY_ID` | Same Key ID as step 2 |
| `ASC_API_ISSUER_ID` | Same Issuer ID as step 2 |
| `SPARKLE_ED25519_PRIVATE_KEY` | Output of `generate_keys -x <file>` (the **private** key — `-p` prints the public key, which is wrong here) |

## 5. GitHub Pages (Sparkle appcast hosting)

1. **github.com/thirteen37/talaria → Settings → Pages**.
2. **Source:** "Deploy from a branch".
3. **Branch:** `main`, **Folder:** `/docs`.
4. Save.

The appcast will then be served at
`https://thirteen37.github.io/talaria/appcast.xml`, which matches
`SUFeedURL` in `Talaria/Info.plist`.

## 6. Hermes capability version pins — DONE

`HermesKit/Sources/HermesKit/Hermes/Capabilities.swift` carries real
minimums resolved from the Hermes git history against `pyproject.toml`
semver at each calver tag:

| Capability | Min Hermes | First shipped in | Source |
| --- | --- | --- | --- |
| `acp` | `0.3.0` | `v2026.3.17` | PR #1254 (ACP adapter) |
| `permissions` | `0.3.0` | `v2026.3.17` | ships with ACP adapter |
| `diffs` | `0.3.0` | `v2026.3.17` | ships with ACP adapter |
| `toolsEnablePerPlatform` | `0.4.0` | `v2026.3.23` | PR #1652 |
| `requiresDashboard` | `0.14.0` | `v2026.5.16` | FastAPI dashboard verified live |

If Hermes ships a future release that changes any of these guarantees,
re-resolve with:

```sh
cd /tmp/hermes
git log --reverse --format="%h %ad" --date=short -S 'add_parser("<verb>"' -- hermes_cli/
# then map the commit to the first tag containing it:
git merge-base --is-ancestor <commit> v2026.X.Y && echo "in this tag"
git show v2026.X.Y:pyproject.toml | grep '^version'
```

## 7. Wire `CapabilityTable` consumers in Manage views — DONE

Dashboard-backed Manage views consume
`capabilityBanner(.<cap>, feature:, version:)` (defined in
`Talaria/Manage/ManageHarness.swift`) and surface an orange `.warning`
banner when the probed profile's Hermes version is below the dashboard pin. `ToolsView` still checks `toolsEnablePerPlatform` because enable/disable remains on the CLI path. Hard
runtime errors still take precedence (red `.error` banner).

`SkillsView`, `CronView`, `LogsView`, and `UpdatesView` use the
dashboard gate. `ToolsView` uses `toolsEnablePerPlatform` until Hermes
ships dashboard tool-toggle routes.

Banners only show when `ServerProfile.version` is non-nil (i.e. the user
has run the probe in the profile editor at least once). Unprobed profiles
remain silent — we'd rather under-warn than nag.

## 8. Tag v1.0

Once 1-7 are done:

```sh
git tag v1.0
git push origin v1.0
```

The `Release` workflow will pick it up and produce a signed, notarised DMG
attached to the GitHub Release plus a PR updating `docs/appcast.xml`.

Then smoke-test the artefact and verify the appcast/update path described in
`docs/release.md`.

## 9. iOS / iPadOS TestFlight

The macOS pipeline above (Developer ID → notarise → DMG → Sparkle) does **not**
apply to iOS. App Store / TestFlight is a separate signing identity, profile,
and upload path. `scripts/release-ios.sh` archives the `TalariaIOS` scheme with
App Store signing and uploads to App Store Connect.

The repo-side prerequisites are already done: the iOS app icon is an opaque
full-bleed 1024 (`Talaria/Assets.xcassets/AppIcon.appiconset/icon_ios_1024.png`),
`ITSAppUsesNonExemptEncryption` is set in `Talaria/Info-iOS.plist`, and a
privacy manifest ships in `Talaria/PrivacyInfo.xcprivacy`. The steps below are
the **manual / account-side** work that cannot be scripted from this repo.

### 9a. Apple Distribution certificate — REQUIRED

The certs on file (`Apple Development`, `Developer ID Application`) do **not**
sign App Store builds. Create an **Apple Distribution** certificate:

1. [developer.apple.com → Certificates → Create](https://developer.apple.com/account/resources/certificates/add)
   → **Apple Distribution** → follow the CSR flow → download → double-click to install.
2. Verify: `security find-identity -v -p codesigning` lists
   `"Apple Distribution: YU XI LIM (9URLHJ84PY)"`.

### 9b. Explicit App ID — REQUIRED

The iOS target uses `io.lyx.Talaria` (`project.yml`) — a distinct, owned
reverse-domain id, separate from the macOS target's `com.talaria.Talaria`. The
macOS id is deliberately left unchanged: it ships via GitHub + Sparkle, and
Sparkle refuses to install an update whose `CFBundleIdentifier` differs from the
installed host, so renaming it would strand every existing v1.0 user and orphan
their preferences. Keeping the ids separate has no downside — the macOS app is
not in App Store Connect, so there is no record collision.

1. [developer.apple.com → Identifiers → Register an App ID](https://developer.apple.com/account/resources/identifiers/add/bundleId)
   → **App** → explicit Bundle ID `io.lyx.Talaria` → no extra capabilities
   needed for v1.

### 9c. App Store Connect app record — REQUIRED

1. Sign the **Paid/Free Apps agreement** in App Store Connect → Agreements
   (TestFlight is blocked until this is signed).
2. [appstoreconnect.apple.com → Apps → +](https://appstoreconnect.apple.com/apps)
   → New App → Platform **iOS** → the bundle id from 9b → SKU + name
   (confirm "Talaria" is available).

### 9d. App Store Connect API key — **Admin role** — REQUIRED

**The key must be Admin (or Account Holder) — not App Manager, not Developer.**
Cloud-managed distribution signing (`-allowProvisioningUpdates`) creates a
distribution *certificate* through the API key, and only Admin / Account Holder
roles may manage certificates. A Developer- or App-Manager-role key archives
fine but fails the export step with:

```
error: exportArchive Cloud signing permission error
error: exportArchive No profiles for 'io.lyx.Talaria' were found
```

1. App Store Connect → Users and Access → Integrations → App Store Connect API
   → **Team Keys** → **+** → Access **Admin** → Generate → download the `.p8`
   (one-time), note the **Key ID** and **Issuer ID**.

The macOS notarisation pipeline (§2/§4) shares these `ASC_API_*` secrets; an
Admin key notarises perfectly well, so replacing the old Developer
`TalariaNotary` key with this Admin key does **not** break the macOS release.
Leave the old key active if you still run `scripts/release.sh` locally — its
local `TalariaNotary` keychain profile points at it.

### 9e. GitHub secrets (environment: `release`)

The CI lane (§9g) reuses the macOS pipeline's `KEYCHAIN_PASSWORD` and the three
`ASC_API_*` secrets — now pointing at the **Admin** key from §9d — plus the iOS
Distribution cert. Set these in the **`release`** environment (Settings →
Environments → release → Secrets), matching the existing macOS secrets:

| Secret | How to produce |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Keychain Access → expand the **Apple Distribution** cert → select the cert **and** its private key → **Export 2 Items** as `.p12` **with an empty password** → `base64 -i dist.p12 \| pbcopy` |
| `ASC_API_KEY_BASE64` | `base64 -i ~/.private/AuthKey_<keyid>.p8 \| pbcopy` (the **Admin** key from §9d) |
| `ASC_API_KEY_ID` | The Admin key's Key ID |

`ASC_API_ISSUER_ID` is the same for every team key, so it does **not** change
when you swap keys. The `.p12` is exported with an **empty password**, so there
is no `IOS_DISTRIBUTION_P12_PASSWORD` secret — the workflow imports with
`-P ""`. (If you prefer a password, set that secret and the workflow uses it.)

### 9f. Export-compliance declaration — CONFIRM

`Info-iOS.plist` ships `ITSAppUsesNonExemptEncryption = false`, declaring the
app uses only exempt encryption (standard SSH/TLS transport). This is a legal
self-classification to Apple/BIS — confirm it matches your distribution before
submitting. If it does not, set it `true` and complete the compliance
documentation App Store Connect prompts for.

### 9g. Cutting a release — `.github/workflows/ios-testflight.yml`

The deploy workflow archives, signs, and uploads `TalariaIOS` to TestFlight by
running `scripts/release-ios.sh`. It runs on a **`macos-26`** runner and selects
**Xcode 26**, because App Store Connect rejects any upload not built with the
iOS 26 SDK. It is **`workflow_dispatch` only** — it does *not* fire on `v*`
tags, so the macOS DMG release and the iOS TestFlight push stay independent.
(The comment at the top of the file shows how to add a tag trigger later.) The
workflow must live on the default branch (`main`) for `workflow_dispatch` to be
available — it already does.

**From the GitHub UI:** Actions → **iOS TestFlight** → **Run workflow** ▾ →
leave "Use workflow from" on **main** → enter the version (e.g. `1.1`) → **Run
workflow**.

**From the CLI:**

```sh
gh workflow run ios-testflight.yml --ref main -f version=1.1
# then watch the run:
gh run watch "$(gh run list --workflow=ios-testflight.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

You supply only the marketing **version**; `CFBundleVersion` is set from
`date -u +%Y%m%d.%H%M`, so TestFlight's monotonic build number is satisfied
automatically. The App ID (§9b), app record (§9c), Admin key (§9d), and secrets
(§9e) must be in place and the Paid/Free Apps agreement signed. On success the
build lands in App Store Connect → TestFlight after a few minutes of Apple
processing.

### 9h. TestFlight testers

- **Internal** testers (your team, ≤100) need no review — fastest first loop.
- **External** testers require a one-time **Beta App Review** plus a beta
  description and feedback email. Because Talaria connects to a *user-supplied*
  Hermes server, add review notes explaining the self-hosted-backend
  requirement (or provide a demo server) — reviewers cannot exercise it blind.

### 9i. Local / manual run (fallback)

Run the upload from your Mac — needs Xcode 26 selected, the Apple Distribution
cert in the login keychain, and the Admin `.p8`:

```sh
sudo xcode-select -s /Applications/Xcode_26.app/Contents/Developer
ASC_KEY_ID=<keyid> ASC_ISSUER_ID=<issuer> ASC_KEY_PATH=~/.private/AuthKey_<keyid>.p8 \
  scripts/release-ios.sh 1.1
```

Or build a signed `.ipa` for manual upload via Xcode Organizer / Transporter
(no API key needed):

```sh
scripts/release-ios.sh --export-only
```

### 9j. Troubleshooting (lessons from first bring-up)

- **`Cloud signing permission error` / `No profiles for 'io.lyx.Talaria' were found`**
  at export → the `ASC_API_*` key is not Admin. Distribution cloud signing
  creates a certificate, which only Admin / Account Holder keys may do (§9d).
- **`SDK version issue … must be built with the iOS 26 SDK`** at upload → the
  runner is on an old Xcode. The job must run on `macos-26` with Xcode 26
  selected (already configured in the workflow).
- **"Run workflow" button missing / `workflow_dispatch` unavailable** → the
  workflow file isn't on the default branch; it must be on `main`.
- **`archive missing app …`** locally → stale checkout; the script resolves the
  product as `TalariaIOS.app` (the target name), not `Talaria.app`.
