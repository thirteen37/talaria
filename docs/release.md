# Release

This document covers cutting a signed, notarised, auto-updating Talaria
release. Anything that requires per-developer secrets (team ID, API keys,
Sparkle private key) lives in [`RELEASE_SETUP.md`](../RELEASE_SETUP.md);
this file describes the steady-state process.

## Overview

Each release goes through six steps, all driven by `scripts/release.sh`:

1. **Archive** — `xcodebuild archive` against `project.yml` configuration.
2. **Sign** — Developer ID Application with Hardened Runtime + secure timestamp.
3. **Notarise** — `xcrun notarytool submit --wait` using a keychain profile.
4. **Staple** — `xcrun stapler staple` on the app and the DMG.
5. **Verify** — `codesign --verify --deep --strict --verbose=2`, `stapler validate`, `spctl -a -vvv -t install`.
6. **Publish** — DMG to GitHub Releases, Sparkle appcast entry committed under `docs/appcast.xml` (served by GitHub Pages).

## Local release

Run:

```sh
scripts/release.sh                  # uses ./VERSION
scripts/release.sh 1.1.0            # override version
scripts/release.sh --skip-notarize  # build + sign locally only
```

Artifacts land under `build/`:

```
build/Talaria.xcarchive
build/export/Talaria.app
build/Talaria-<VERSION>.dmg
build/sparkle-signature.txt   # ed25519 line for appcast
```

## CI release

Push a tag matching `v*` to trigger `.github/workflows/release.yml`. The
workflow restores the Developer-ID certificate and App Store Connect API key
from repo secrets, runs `scripts/release.sh`, uploads the DMG to the GitHub
Release, and opens a PR updating `docs/appcast.xml`.

Required GitHub repo secrets (set in **Settings → Secrets → Actions**):

| Secret | Source |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` of your exported certificate + key |
| `DEVELOPER_ID_P12_PASSWORD` | The password set during export |
| `KEYCHAIN_PASSWORD` | Any strong random string (CI-local keychain) |
| `ASC_API_KEY_BASE64` | `base64 -i AuthKey_XXXXX.p8 \| pbcopy` |
| `ASC_API_KEY_ID` | 10-char key ID from App Store Connect |
| `ASC_API_ISSUER_ID` | UUID issuer ID from App Store Connect |
| `SPARKLE_ED25519_PRIVATE_KEY` | Output of `generate_keys -x <file>` (base64). Optional — release runs with `--skip-sign-update` if absent |

## Sparkle

- Public key lives in `Talaria/Info.plist` as `SUPublicEDKey`.
- Private key lives in the login Keychain (item: `https://sparkle-project.org`).
- Feed URL: `https://thirteen37.github.io/talaria/appcast.xml` (GitHub Pages).
- Appcast source lives at `docs/appcast.xml` and is served by GitHub Pages from `main`/`docs/`.

### Sparkle footgun

**Do not** add `--deep` to the `codesign` invocation. Sparkle ships nested
helper apps (XPC services + Autoupdate) that are pre-signed by Sparkle's
build system and must be signed individually by `xcodebuild` during export.
A `--deep` re-sign breaks Sparkle's helper validation at runtime.

If a release does need an ad-hoc re-sign (e.g. to swap entitlements), sign
each helper explicitly:

```sh
codesign --sign "Developer ID Application" --options=runtime --timestamp \
    Talaria.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
codesign --sign "Developer ID Application" --options=runtime --timestamp \
    Talaria.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
codesign --sign "Developer ID Application" --options=runtime --timestamp \
    Talaria.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
codesign --sign "Developer ID Application" --options=runtime --timestamp \
    Talaria.app/Contents/Frameworks/Sparkle.framework
codesign --sign "Developer ID Application" --options=runtime --timestamp \
    --entitlements Talaria/Talaria.entitlements Talaria.app
```

## Version bump conventions

- `MARKETING_VERSION` (visible) — semver in `VERSION`.
- `CURRENT_PROJECT_VERSION` (build counter) — `git rev-list --count HEAD` (set automatically by `scripts/release.sh`).
- Tag releases as `v<MARKETING_VERSION>` (e.g. `v1.0.0`).

## Verification checklist

After `scripts/release.sh` completes:

```sh
codesign --verify --deep --strict --verbose=2 build/export/Talaria.app
xcrun stapler validate build/export/Talaria.app
xcrun stapler validate build/Talaria-1.0.0.dmg
spctl -a -vvv -t install build/export/Talaria.app
# Expect:  accepted source=Notarized Developer ID
```

## Deferred decisions

- Sparkle update channels (stable / beta).
- Inline HTML release notes per `<item>`.
- Mac App Store distribution (would require re-enabling sandbox).
