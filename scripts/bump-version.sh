#!/usr/bin/env bash
# Bump the marketing version everywhere it is committed, in one place, so a
# release can never go out with stale version metadata. Updates:
#   - ./VERSION                      (release-script default / fallback)
#   - project.yml MARKETING_VERSION  (Xcode source of truth; macOS + iOS targets)
# then regenerates Talaria.xcodeproj when xcodegen is available.
#
#   scripts/bump-version.sh 1.1
#
# Run this, review + commit, then tag v<version> to release. scripts/release.sh
# and scripts/release-ios.sh refuse to build if these values disagree with the
# version being released, so a forgotten bump fails the release loudly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/bump-version.sh <major.minor>   (e.g. 1.1)" >&2
    exit 1
fi

printf '%s\n' "$VERSION" > "${REPO_ROOT}/VERSION"
# Rewrite every MARKETING_VERSION line (both app targets) in place. BSD sed (-i '')
# — this is a macOS-only project. CURRENT_PROJECT_VERSION is the build number,
# set per-release by date, so it is intentionally left alone here.
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*).*/\1${VERSION}/" "${REPO_ROOT}/project.yml"

echo "Set marketing version to ${VERSION} in VERSION and project.yml."
if command -v xcodegen >/dev/null 2>&1; then
    ( cd "${REPO_ROOT}" && xcodegen generate >/dev/null )
    echo "Regenerated Talaria.xcodeproj."
else
    echo "note: xcodegen not found — run 'xcodegen generate' before building." >&2
fi
echo "Next: review, commit, then tag v${VERSION} to cut the release."
