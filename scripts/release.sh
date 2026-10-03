#!/bin/bash
# Build a signed, notarized amdgpu_mtopg disk image for distribution.
#
# Usage: scripts/release.sh
#
# Environment:
#   SIGN_IDENTITY    codesign identity (default: "Developer ID Application")
#   NOTARY_PROFILE   notarytool keychain profile (default: AC_PASSWORD), created
#                    once with `xcrun notarytool store-credentials`
#   SKIP_NOTARIZE=1  sign only (the image will not pass Gatekeeper on other Macs)
#
# Output: build/amdgpu_mtopg-<version>.dmg and its .sha256
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
APP=build/amdgpu_mtopg.app

./build.sh --clean
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/amdgpu_mtopg-$VERSION.dmg"

notarize() {
  [[ "${SKIP_NOTARIZE:-0}" == 1 ]] && { echo "==> skipping notarization of $1"; return; }
  echo "==> notarizing $1"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

echo "==> signing $APP with \"$IDENTITY\" (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize the app on its own so it carries a stapled ticket after it is copied
# out of the disk image.
zip="build/amdgpu_mtopg-$VERSION-app.zip"
ditto -c -k --keepParent "$APP" "$zip"
notarize "$zip"
rm -f "$zip"
[[ "${SKIP_NOTARIZE:-0}" == 1 ]] || xcrun stapler staple "$APP"

echo "==> creating $DMG"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/amdgpu_mtopg.app"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "amdgpu_mtopg $VERSION" -srcfolder "$stage" \
  -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "==> $DMG"
cat "$DMG.sha256"
