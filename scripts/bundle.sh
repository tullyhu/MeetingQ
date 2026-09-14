#!/bin/bash
set -euo pipefail

APP_NAME="MeetingQ"
BIN_NAME="MeetingQ"
MODE="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/${APP_NAME}.app"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

WORKAROUND_DIR="$ROOT/.build-workaround"
mkdir -p "$WORKAROUND_DIR"

VFS_ARGS=()
STALE_MODULEMAP="$(xcode-select -p)/usr/include/swift/module.modulemap"
if [ -f "$STALE_MODULEMAP" ] && [ -f "$(xcode-select -p)/usr/include/swift/bridging.modulemap" ]; then
  echo '// intentionally empty' > "$WORKAROUND_DIR/empty.modulemap"
  cat > "$WORKAROUND_DIR/mm-vfs.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "name": "$STALE_MODULEMAP",
      "type": "file",
      "external-contents": "$WORKAROUND_DIR/empty.modulemap"
    }
  ]
}
EOF
  VFS_ARGS=(-vfsoverlay "$WORKAROUND_DIR/mm-vfs.yaml")
  echo "Applying CLT SwiftBridging modulemap workaround"
fi

OPT_FLAGS=()
if [ "$MODE" = "release" ]; then
  OPT_FLAGS=(-O)
fi

cd "$ROOT"
mkdir -p "$ROOT/dist"

echo "Compiling ($MODE)..."
swiftc ${VFS_ARGS[@]+"${VFS_ARGS[@]}"} \
  -target arm64-apple-macos15.0 \
  -sdk "$SDK_PATH" \
  -swift-version 5 \
  ${OPT_FLAGS[@]+"${OPT_FLAGS[@]}"} \
  -module-name MeetingQ \
  $(find Sources/MeetingQCore Sources/MeetingQ -name '*.swift') \
  -o "$ROOT/dist/$BIN_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT/dist/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi

if [ -z "${CODESIGN_IDENTITY:-}" ] && security find-certificate -c "MeetingQ Dev" >/dev/null 2>&1; then
  CODESIGN_IDENTITY="MeetingQ Dev"
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  KEYCHAIN_ARGS=()
  if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    if [ -n "${MM_KEYCHAIN_PASSWORD:-}" ]; then
      security unlock-keychain -p "$MM_KEYCHAIN_PASSWORD" "$CODESIGN_KEYCHAIN" 2>/dev/null || true
    fi
    KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
  fi
  ENTITLEMENTS="$ROOT/Resources/MeetingQ.entitlements"
  case "$CODESIGN_IDENTITY" in
    *"Developer ID"*|*"Apple Development"*|*"Distribution"*|*"Mac App Store"*) ;;
    *)
      ENTITLEMENTS="$WORKAROUND_DIR/MeetingQ-nosandbox.entitlements"
      cp "$ROOT/Resources/MeetingQ.entitlements" "$ENTITLEMENTS"
      /usr/libexec/PlistBuddy -c "Delete :com.apple.security.app-sandbox" "$ENTITLEMENTS"
      echo "Self-signed identity detected: building without app sandbox (avoids repeated keychain prompts)"
      ;;
  esac
  codesign --force ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --sign "$CODESIGN_IDENTITY" "$APP_DIR"
  echo "Signed with: $CODESIGN_IDENTITY"
else
  codesign --force --sign - "$APP_DIR"
  echo "Ad-hoc signed (set CODESIGN_IDENTITY for distribution)"
fi

echo "Built: $APP_DIR"
