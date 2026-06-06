#!/usr/bin/env bash
# Talaria iOS / iPadOS TestFlight pipeline.
#
#   scripts/release-ios.sh                 # archive + export + upload to TestFlight
#   scripts/release-ios.sh 1.1             # override version (else reads ./VERSION)
#   scripts/release-ios.sh --export-only   # archive + export .ipa, skip upload
#                                          #   (no App Store Connect key needed)
#
# Unlike the macOS pipeline (scripts/release.sh: Developer ID + notarise + DMG +
# Sparkle), App Store distribution signs with an *Apple Distribution* certificate
# and an *App Store* provisioning profile, then uploads the .ipa to App Store
# Connect, where it appears under TestFlight.
#
# Required setup (see RELEASE_SETUP.md §iOS / TestFlight):
#   * Apple Distribution certificate installed in the login keychain
#     (verify: security find-identity -v -p codesigning | grep "Apple Distribution")
#   * An explicit App ID + App Store Connect app record for the bundle id below
#   * App Store Connect API key (.p8) with the App Manager role, for
#     `-allowProvisioningUpdates` and the upload. Provide via env:
#       ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH   (path to the .p8)
#     (Not needed with --export-only.)
#
# Fail-fast: any non-zero exit aborts; artefacts are left under build-ios/.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly SCHEME="TalariaIOS"
readonly CONFIGURATION="Release"
readonly APP_NAME="Talaria"
readonly TEAM_ID="9URLHJ84PY"
readonly BUILD_DIR="${REPO_ROOT}/build-ios"
readonly ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"

EXPORT_ONLY=0
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --export-only) EXPORT_ONLY=1 ;;
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
[[ -n "$VERSION" ]] || { echo "error: could not determine version (set VERSION, pass arg, or tag the repo)" >&2; exit 1; }

# TestFlight requires CFBundleVersion to strictly increase across uploads for a
# given marketing version. Date-based UTC matches scripts/release.sh and is
# always monotonic. App Store Connect accepts period-separated integers.
BUILD_NUMBER="$(date -u +%Y%m%d.%H%M)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

log "iOS release ${VERSION} (build ${BUILD_NUMBER})"

# Validate upload credentials up front so we don't archive for 5 minutes and
# then fail at the last step.
AUTH_FLAGS=()
if [[ $EXPORT_ONLY -eq 0 ]]; then
    : "${ASC_KEY_ID:?set ASC_KEY_ID (or pass --export-only)}"
    : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (or pass --export-only)}"
    : "${ASC_KEY_PATH:?set ASC_KEY_PATH to the .p8 file (or pass --export-only)}"
    [[ -f "$ASC_KEY_PATH" ]] || fail "ASC_KEY_PATH does not exist: ${ASC_KEY_PATH}"
    AUTH_FLAGS=(
        -allowProvisioningUpdates
        -authenticationKeyPath "$ASC_KEY_PATH"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
fi

# 1. clean --------------------------------------------------------------------
rm -rf "${BUILD_DIR}"
mkdir -p "${EXPORT_DIR}"

# 2. regenerate Xcode project -------------------------------------------------
log "xcodegen generate"
xcodegen generate

# 3. archive (Apple Distribution signing) -------------------------------------
# Automatic signing + -allowProvisioningUpdates lets xcodebuild create/fetch the
# App Store provisioning profile via the API key. Drop AUTH_FLAGS in
# --export-only mode (automatic signing then resolves against locally cached
# profiles / a logged-in Xcode account).
log "xcodebuild archive (iOS)"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    "${AUTH_FLAGS[@]}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    archive

# The archive's product is named after the target (TalariaIOS.app), not the
# display APP_NAME. Resolve the single .app rather than hardcoding the name.
APP_PATH="$(ls -d "${ARCHIVE_PATH}"/Products/Applications/*.app 2>/dev/null | head -n 1 || true)"
[[ -n "${APP_PATH}" && -d "${APP_PATH}" ]] || fail "no .app in ${ARCHIVE_PATH}/Products/Applications"

# 4. export / upload ----------------------------------------------------------
# destination=upload sends the build straight to App Store Connect (TestFlight);
# destination=export just writes a signed .ipa for manual upload via Xcode
# Organizer or Transporter.
DESTINATION="upload"
[[ $EXPORT_ONLY -eq 1 ]] && DESTINATION="export"

cat > "${BUILD_DIR}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>${DESTINATION}</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
PLIST

log "xcodebuild -exportArchive (destination=${DESTINATION})"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    "${AUTH_FLAGS[@]}"

log "done"
if [[ $EXPORT_ONLY -eq 1 ]]; then
    echo "Exported .ipa under: ${EXPORT_DIR}"
    echo "Upload manually via Xcode Organizer or: xcrun altool --upload-app -f <ipa> -t ios --apiKey <id> --apiIssuer <issuer>"
else
    echo "Uploaded build ${VERSION} (${BUILD_NUMBER}) to App Store Connect."
    echo "It will appear in TestFlight after Apple finishes processing (usually a few minutes)."
fi
