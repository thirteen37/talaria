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

## 3. Sparkle ed25519 key pair

`Talaria/Info.plist` has `SUPublicEDKey` set to a placeholder. Generate the
real keypair and replace it.

1. Build the project once in Xcode so SPM resolves Sparkle.
2. Locate `generate_keys`:
   ```sh
   find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f
   ```
3. Run it:
   ```sh
   /path/to/generate_keys
   ```
   The first invocation stores the **private key** in your login Keychain
   (item: `https://sparkle-project.org`) and prints the **public key**
   as a base64 string.
4. Paste the public key into `Talaria/Info.plist` under `SUPublicEDKey`,
   replacing `REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY`.

For CI, export the private key once to a file (the `-x` flag writes the
key out as base64; `-p` would print the **public** key, which is the
wrong direction):

```sh
/path/to/generate_keys -x /tmp/sparkle_priv.key
pbcopy < /tmp/sparkle_priv.key
shred -u /tmp/sparkle_priv.key   # or `rm -P` on macOS
```

Paste the contents into the `SPARKLE_ED25519_PRIVATE_KEY` GitHub secret
(in the `release` environment — see §4).
**This is a long-lived signing key.** If it leaks, attackers can publish
updates that the app will trust; rotate immediately by generating a new
pair and shipping an update with the new public key.

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
| `SPARKLE_ED25519_PRIVATE_KEY` | Output of `generate_keys -p` |

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
| `cronCRUD` | `0.3.0` | `v2026.3.17` | `cron add/update/delete/pause/resume/run` verbs |
| `skillsToggle` | `0.2.0` | `v2026.3.12` | PR #642 |
| `toolsEnablePerPlatform` | `0.4.0` | `v2026.3.23` | PR #1652 |
| `updateCheck` | `0.12.0` | `v2026.4.30` | PR #10318 |

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

`CronView`, `ToolsView`, and `UpdatesView` now consume
`capabilityBanner(.<cap>, feature:, version:)` (defined in
`Talaria/Manage/ManageHarness.swift`) and surface an orange `.warning`
banner when the probed profile's Hermes version is below the pin. Hard
runtime errors still take precedence (red `.error` banner).

`SkillsView` is intentionally skipped: Talaria 1.0 renders skills
read-only (no scriptable toggle UI), so a pre-emptive gate would be
banner noise. Wire it back in if/when Talaria starts calling
`hermes skills enable/disable`.

Banners only show when `ServerProfile.version` is non-nil (i.e. the user
has run the probe in the profile editor at least once). Unprobed profiles
remain silent — we'd rather under-warn than nag.

## 8. Tag v1.0

Once 1-7 are done:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The `Release` workflow will pick it up and produce a signed, notarised DMG
attached to the GitHub Release plus a PR updating `docs/appcast.xml`.

Then execute the manual test plan (`docs/test-plan.md`) against the
artefact, including the **Release artifact verification** section.
