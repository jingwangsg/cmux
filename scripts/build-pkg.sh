#!/usr/bin/env bash
set -euo pipefail

# Build cmux.app and package it as a macOS .pkg installer.
# Usage: ./scripts/build-pkg.sh [--sign] [--notarize]
#
# Options:
#   --sign        Codesign the app and the pkg (requires signing identity)
#   --notarize    Also notarize (implies --sign, requires Apple credentials)
#
# Output: cmux-macos.pkg in the repo root.

SIGN=false
NOTARIZE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)      SIGN=true; shift ;;
    --notarize)  NOTARIZE=true; SIGN=true; shift ;;
    *)           echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SIGN_HASH="A050CC7E193C8221BDBA204E731B046CDCCC1B30"
INSTALLER_SIGN_ID="3rd Party Mac Developer Installer: Jing Wang (${APPLE_TEAM_ID:-MISSING})"
ENTITLEMENTS="cmux.entitlements"
BUILD_DIR="build-pkg"
APP_PATH="$BUILD_DIR/Build/Products/Release/cmux.app"
PKG_OUTPUT="cmux-macos.pkg"
COMPONENT_PKG="cmux-component.pkg"

# --- Pre-flight ---
for tool in xcodebuild pkgbuild productbuild; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done

# --- Build GhosttyKit (if needed) ---
./scripts/ensure-ghosttykit.sh

# --- Build app (Release) ---
echo "Building Release app..."
rm -rf "$BUILD_DIR"
if [[ "$SIGN" == "true" ]]; then
  xcodebuild -scheme cmux -configuration Release -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
else
  xcodebuild -scheme cmux -configuration Release -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
fi
echo "Build succeeded"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: App not found at $APP_PATH" >&2
  exit 1
fi

# --- Codesign (optional) ---
if [[ "$SIGN" == "true" ]]; then
  echo "Codesigning app..."
  CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
  HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
  [ -f "$CLI_PATH" ] && /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$CLI_PATH"
  [ -f "$HELPER_PATH" ] && /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$HELPER_PATH"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  echo "Codesign verified"
fi

# --- Build .pkg ---
echo "Building .pkg installer..."
rm -f "$COMPONENT_PKG" "$PKG_OUTPUT"

# Component pkg: installs cmux.app into /Applications
pkgbuild \
  --root "$APP_PATH" \
  --install-location "/Applications/cmux.app" \
  --identifier "com.cmuxterm.app" \
  --version "$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)" \
  "$COMPONENT_PKG"

# Product pkg: wraps the component with a title
if [[ "$SIGN" == "true" ]] && security find-identity -v -p basic 2>/dev/null | grep -q "Mac Developer Installer"; then
  productbuild \
    --package "$COMPONENT_PKG" \
    --sign "$INSTALLER_SIGN_ID" \
    "$PKG_OUTPUT"
else
  productbuild \
    --package "$COMPONENT_PKG" \
    "$PKG_OUTPUT"
fi

rm -f "$COMPONENT_PKG"
echo "Package created: $PKG_OUTPUT"

# --- Notarize (optional) ---
if [[ "$NOTARIZE" == "true" ]]; then
  echo "Notarizing .pkg..."
  source ~/.secrets/cmuxterm.env
  xcrun notarytool submit "$PKG_OUTPUT" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
  xcrun stapler staple "$PKG_OUTPUT"
  xcrun stapler validate "$PKG_OUTPUT"
  echo "Notarization complete"
fi

# --- Summary ---
PKG_SIZE=$(du -sh "$PKG_OUTPUT" | cut -f1)
echo ""
echo "=== .pkg build complete ==="
echo "  Output: $REPO_ROOT/$PKG_OUTPUT"
echo "  Size:   $PKG_SIZE"
