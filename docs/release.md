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
scripts/release.sh 1.1              # override version
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
Release, and opens two PRs: one updating `docs/appcast.xml` (Sparkle) and one
updating `Casks/talaria.rb` (Homebrew — version + the new DMG's sha256). The
cask PR runs post-build because the checksum only exists once the DMG is built,
and it is independent of Sparkle so it still opens if the Sparkle key is absent.

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

Bump the marketing version with one command **before** tagging a release:

```sh
scripts/bump-version.sh 1.1   # updates ./VERSION + both project.yml targets, regenerates the project
```

Then review, commit (PR to `main`), and tag `v1.1`. The marketing version lives
in two committed places — `./VERSION` (the release-script default) and
`project.yml`'s `MARKETING_VERSION` (the Xcode source of truth, which feeds
`CFBundleShortVersionString` via `$(MARKETING_VERSION)` in both `Info.plist`s).
`bump-version.sh` keeps them in lockstep, and both release scripts call
`assert_version_metadata` to **abort the build** if either disagrees with the
version being released — so a forgotten bump fails the release loudly instead of
shipping stale metadata.

- `CFBundleShortVersionString` / `MARKETING_VERSION` (visible) — **major.minor**
  in `VERSION` and `project.yml` (e.g. `1.0`).
- `CFBundleVersion` / `CURRENT_PROJECT_VERSION` (build number) —
  **`YYYYMMDD.HHMM` (UTC)**, set automatically by `scripts/release.sh` from
  `date -u +%Y%m%d.%H%M`. Always monotonic with no same-day collisions, and
  Sparkle's `SUStandardVersionComparator` orders these correctly.
- Tag releases as `v<major.minor>` (e.g. `v1.0`).

## Verification checklist

After `scripts/release.sh` completes:

```sh
codesign --verify --deep --strict --verbose=2 build/export/Talaria.app
xcrun stapler validate build/export/Talaria.app
xcrun stapler validate build/Talaria-1.0.dmg
spctl -a -vvv -t install build/export/Talaria.app
# Expect:  accepted source=Notarized Developer ID
```

## Deferred decisions

- Sparkle update channels (stable / beta).
- Inline HTML release notes per `<item>`.
- Mac App Store distribution (would require re-enabling sandbox).
