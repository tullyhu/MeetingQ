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
BUILD_CONFIG="debug"
if [ "$MODE" = "release" ]; then
  BUILD_CONFIG="release"
fi
swift build -c "$BUILD_CONFIG"
BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$BIN_NAME"
cp "$BIN_PATH" "$ROOT/dist/$BIN_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$ROOT/dist/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"

# Copy any SPM-built frameworks the binary links against (e.g. FluidAudio's
# binary targets) and point the rpath at the bundle's Frameworks dir.
BIN_DIR="$(dirname "$BIN_PATH")"
for fw in "$BIN_DIR"/PackageFrameworks/*.framework; do
  [ -e "$fw" ] || continue
  cp -R "$fw" "$APP_DIR/Contents/Frameworks/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$BIN_NAME" 2>/dev/null || true
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" 2>/dev/null || true
fi
# Ship third-party license texts inside the bundle (Apache 2.0 attribution).
if [ -d "$ROOT/Resources/Licenses" ]; then
  cp -R "$ROOT/Resources/Licenses" "$APP_DIR/Contents/Resources/Licenses"
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
