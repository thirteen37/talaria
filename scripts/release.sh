#!/usr/bin/env bash
# Talaria release pipeline.
#
#   scripts/release.sh                  # full release using ./VERSION
#   scripts/release.sh 1.2.0            # override version
#   scripts/release.sh --skip-notarize  # build + sign locally, skip Apple round-trip
#
# Required environment / setup (see RELEASE_SETUP.md):
#   * Developer ID Application certificate installed in login keychain
#   * project.yml `DEVELOPMENT_TEAM` set to your Apple team ID
#   * notarytool keychain profile named TALARIA_NOTARY_PROFILE (default below)
#     (created via: xcrun notarytool store-credentials ...)
#   * Sparkle ed25519 private key stored in login keychain
#   * `create-dmg` available (brew install create-dmg) — falls back to hdiutil
#
# The script is intentionally fail-fast: any non-zero exit aborts and leaves
# build artefacts under build/ for inspection.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly SCHEME="Talaria"
readonly CONFIGURATION="Release"
readonly APP_NAME="Talaria"
readonly BUNDLE_ID="com.talaria.Talaria"
readonly BUILD_DIR="${REPO_ROOT}/build"
readonly ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"
readonly NOTARY_PROFILE="${TALARIA_NOTARY_PROFILE:-TalariaNotary}"
readonly APPCAST_PATH="${REPO_ROOT}/docs/appcast.xml"

SKIP_NOTARIZE=0
SKIP_SIGN_UPDATE=0
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --skip-notarize)     SKIP_NOTARIZE=1 ;;
        --skip-sign-update)  SKIP_SIGN_UPDATE=1 ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) VERSION="$arg" ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    if [[ -f "${REPO_ROOT}/VERSION" ]]; then
        VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
    else
        VERSION="$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
    fi
fi

if [[ -z "$VERSION" ]]; then
    echo "error: could not determine version (set VERSION file, pass arg, or tag the repo)" >&2
    exit 1
fi

BUILD_NUMBER="$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo 1)"

readonly DMG_PATH="${BUILD_DIR}/${APP_NAME}-${VERSION}.dmg"
readonly APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

log "Release ${VERSION} (build ${BUILD_NUMBER})"

# 1. clean previous artifacts -------------------------------------------------
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}"

# 2. regenerate Xcode project from project.yml --------------------------------
log "xcodegen generate"
xcodegen generate

# 3. archive ------------------------------------------------------------------
log "xcodebuild archive"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    archive

# 4. export signed app from archive -------------------------------------------
cat > "${BUILD_DIR}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

log "xcodebuild -exportArchive"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist"

[[ -d "${APP_PATH}" ]] || fail "exported app missing at ${APP_PATH}"

# 5. notarise -----------------------------------------------------------------
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    log "notarytool submit"
    readonly NOTARY_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "${APP_PATH}" "${NOTARY_ZIP}"
    xcrun notarytool submit "${NOTARY_ZIP}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    log "stapler staple (app)"
    xcrun stapler staple "${APP_PATH}"
else
    log "skipping notarisation (--skip-notarize)"
fi

# 6. verify signature + staple ------------------------------------------------
log "codesign --verify"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    log "stapler validate (app)"
    xcrun stapler validate "${APP_PATH}"
    log "spctl assessment"
    spctl -a -vvv -t install "${APP_PATH}" || fail "spctl rejected the app"
fi

# 7. DMG ----------------------------------------------------------------------
log "build DMG"
if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "${APP_NAME} ${VERSION}" \
        --window-pos 200 120 \
        --window-size 600 360 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 160 180 \
        --hide-extension "${APP_NAME}.app" \
        --app-drop-link 440 180 \
        --no-internet-enable \
        "${DMG_PATH}" \
        "${APP_PATH}"
else
    echo "create-dmg not installed; falling back to hdiutil"
    hdiutil create \
        -volname "${APP_NAME} ${VERSION}" \
        -srcfolder "${APP_PATH}" \
        -ov -format UDZO \
        "${DMG_PATH}"
fi

# 8. sign + staple the DMG ----------------------------------------------------
# Only sign when we'll notarise — the DMG signature is what notarytool
# validates. For `--skip-notarize` local dev builds, the unsigned DMG is
# fine. `set -euo pipefail` is on, so this codesign must succeed when
# attempted (no `|| true` masking real signing failures).
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    codesign --sign "Developer ID Application" --timestamp --options=runtime "${DMG_PATH}"

    log "notarytool submit (DMG)"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    log "stapler staple (DMG)"
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
fi

# 9. Sparkle ed25519 signature + appcast entry --------------------------------
if [[ $SKIP_SIGN_UPDATE -eq 0 ]]; then
    SIGN_UPDATE_BIN="$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -type f 2>/dev/null | head -n 1 || true)"
    if [[ -n "${SIGN_UPDATE_BIN}" ]]; then
        log "sign_update (Sparkle ed25519)"
        SIGN_OUTPUT="$("${SIGN_UPDATE_BIN}" "${DMG_PATH}")"
        echo "${SIGN_OUTPUT}"
        echo "${SIGN_OUTPUT}" > "${BUILD_DIR}/sparkle-signature.txt"
        echo
        echo "Append the line above to ${APPCAST_PATH} inside a new <item> block."
    else
        echo "sign_update binary not found; build the app once in Xcode to fetch Sparkle, then re-run."
    fi
else
    log "skipping Sparkle signature (--skip-sign-update)"
fi

log "done"
echo "Artifacts:"
echo "  app: ${APP_PATH}"
echo "  dmg: ${DMG_PATH}"
