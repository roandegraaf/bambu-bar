#!/bin/zsh
# Builds Bambu Bar.app (the menu bar app plus its widget extension) with Xcode.
#   scripts/build.sh                     release build into build/App.noindex/Bambu Bar.app
#                                        (.noindex keeps build copies out of Spotlight and Launchpad)
#   CONFIG=Debug scripts/build.sh
#   ARCHS=arm64 scripts/build.sh        one architecture (default: universal)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh
#                                        signing identity (default: the first Developer ID Application
#                                        identity in the keychain, else ad-hoc; the widget needs a real one)
#   TEAM_ID=XXXXXXXXXX scripts/build.sh  team for the app group shared with the widget (default: DEVELOPMENT_TEAM
#                                        in Config/Local.xcconfig, else PCZ6F8Q9DZ); also picks that team's Developer ID
set -euo pipefail

ROOT=${0:A:h:h}
CONFIG=${CONFIG:-Release}
LOCAL_TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$ROOT/Config/Local.xcconfig" 2>/dev/null | tail -1)
TEAM_ID=${TEAM_ID:-${LOCAL_TEAM:-PCZ6F8Q9DZ}}
APP_GROUP="$TEAM_ID.dev.rolottr.BambuBar"
BUILD="$ROOT/build"
APP="$BUILD/App.noindex/Bambu Bar.app"
DERIVED="$BUILD/DerivedData.noindex"
cd "$ROOT"
mkdir -p "$BUILD"

# Use Xcode without changing the global developer directory (the widget needs the full SDK).
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 2; }

echo "==> App icon"
rm -rf "$BUILD/AppIcon.iconset"
swift "$ROOT/scripts/generate-icon.swift" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

echo "==> Generating Xcode project"
xcodegen generate --quiet --spec "$ROOT/project.yml" --project "$ROOT"

echo "==> xcodebuild ($CONFIG)"
xcodebuild -project BambuBar.xcodeproj -scheme BambuBar -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)" ${ARCHS:+ARCHS=$ARCHS} \
  -quiet build

rm -rf "$APP"
mkdir -p "${APP:h}"
ditto "$DERIVED/Build/Products/$CONFIG/Bambu Bar.app" "$APP"

# Sign inside-out: the widget (sandboxed) first, then the app. Entitlements get the concrete app group.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  identities=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2}')
  SIGN_IDENTITY=$(print -r -- "$identities" | grep -F "($TEAM_ID)" | head -1)
  [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY=$(print -r -- "$identities" | head -1)
fi
ENT="$BUILD/entitlements"
mkdir -p "$ENT"
for f in BambuBar BambuBarWidget; do
  sed "s/\$(APP_GROUP)/$APP_GROUP/g" "$ROOT/Resources/Signing/$f.entitlements" > "$ENT/$f.entitlements"
done
WIDGET="$APP/Contents/PlugIns/BambuBarWidget.appex"
HELPER="$APP/Contents/MacOS/bambu-camera"
SIGNATURE_LIB="$APP/Contents/MacOS/libbambu-camera-signature.dylib"
[[ -x "$HELPER" ]] || { echo "Camera helper is missing" >&2; exit 1; }
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "==> Signing with $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$SIGNATURE_LIB"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Resources/Signing/BambuCamera.entitlements" "$HELPER"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ENT/BambuBarWidget.entitlements" "$WIDGET"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ENT/BambuBar.entitlements" "$APP"
else
  echo "==> Ad-hoc signing (no Developer ID identity found; the widget won't load)"
  codesign --force --sign - "$SIGNATURE_LIB"
  codesign --force --sign - --entitlements "$ROOT/Resources/Signing/BambuCamera.entitlements" "$HELPER"
  codesign --force --sign - --entitlements "$ENT/BambuBarWidget.entitlements" "$WIDGET"
  codesign --force --sign - --entitlements "$ENT/BambuBar.entitlements" "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "==> Built $APP"
