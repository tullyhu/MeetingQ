#!/bin/bash
set -euo pipefail

APP_NAME="CalledMe"
VERSION="${VERSION:-1.0.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
DMG_PATH="$ROOT/dist/${APP_NAME}-${VERSION}.dmg"
STAGING="$ROOT/dist/dmg-staging"

"$ROOT/scripts/bundle.sh" release

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  KEYCHAIN_ARGS=()
  if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    if [ -n "${MM_KEYCHAIN_PASSWORD:-}" ]; then
      security unlock-keychain -p "$MM_KEYCHAIN_PASSWORD" "$CODESIGN_KEYCHAIN" 2>/dev/null || true
    fi
    KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  codesign --force ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  echo "Notarized and stapled"
fi

echo "DMG: $DMG_PATH"
