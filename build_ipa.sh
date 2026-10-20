#!/usr/bin/env bash
#
# SwiftPad — build an unsigned (or re-signed) IPA from source.
#
#   ./build_ipa.sh                       -> build/SwiftPad.ipa  (unsigned)
#   SIGN_IDENTITY="Apple Development: name (TEAMID)" \
#   PROFILE=/path/to/profile.mobileprovision \
#   ./build_ipa.sh                       -> build/SwiftPad-signed.ipa
#
set -euo pipefail
cd "$(dirname "$0")"

SCHEME="SwiftPad"
CONFIG="Release"
BUILD_DIR="build"
APP_NAME="SwiftPad"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
need xcodebuild

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found — install with: brew install xcodegen"
  exit 1
fi

echo "==> generating project"
xcodegen generate --quiet

echo "==> building ($CONFIG, iphoneos)"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "${SCHEME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}-iphoneos/${APP_NAME}.app"
[ -d "$APP_PATH" ] || { echo "build produced no app at $APP_PATH"; exit 1; }

rm -rf Payload "${APP_NAME}.ipa" "${APP_NAME}-signed.ipa"
mkdir -p Payload
cp -R "$APP_PATH" "Payload/${APP_NAME}.app"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> signing with: $SIGN_IDENTITY"
  ENT="entitlements.plist"
  if [ ! -f "$ENT" ]; then
    cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>TEAMID.com.rna.swiftpad</string>
    <key>com.apple.developer.team-identifier</key>
    <string>TEAMID</string>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
PLIST
    echo "    wrote $ENT — replace TEAMID with your team id"
  fi

  if [ -n "${PROFILE:-}" ]; then
    cp "$PROFILE" "Payload/${APP_NAME}.app/embedded.mobileprovision"
  fi

  codesign -f -s "$SIGN_IDENTITY" --entitlements "$ENT" "Payload/${APP_NAME}.app"
  /usr/bin/zip -qry "${APP_NAME}-signed.ipa" Payload
  echo "==> done: ${APP_NAME}-signed.ipa"
else
  /usr/bin/zip -qry "${APP_NAME}.ipa" Payload
  echo "==> done: ${APP_NAME}.ipa (unsigned)"
  echo "    install with Sideloadly / AltStore / TrollStore / Xcode Devices"
fi

rm -rf Payload
