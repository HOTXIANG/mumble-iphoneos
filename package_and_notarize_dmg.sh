#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 /path/to/App.app"
  exit 1
fi

APP_PATH="$1"
APP_NAME="$(basename "$APP_PATH" .app)"
APP_DIR="$(cd "$(dirname "$APP_PATH")" && pwd)"
DMG_PATH="$APP_DIR/$APP_NAME.dmg"
VOL_NAME="$APP_NAME"
KEYCHAIN_PROFILE="mumble-notary"

log() {
  echo
  echo "==> $1"
}

fail() {
  echo
  echo "ERROR: $1" >&2
  exit 1
}

[ -d "$APP_PATH" ] || fail "App not found: $APP_PATH"

log "Stapling app"
xcrun stapler staple "$APP_PATH"

log "Validating app staple"
xcrun stapler validate "$APP_PATH"

log "Verifying app code signature"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

log "Assessing app with Gatekeeper"
spctl --assess --type execute --verbose=4 "$APP_PATH"

if [ -f "$DMG_PATH" ]; then
  log "Removing old DMG"
  rm -f "$DMG_PATH"
fi

log "Creating DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

log "Submitting DMG for notarization"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

log "Stapling DMG"
xcrun stapler staple "$DMG_PATH"

log "Validating DMG staple"
xcrun stapler validate "$DMG_PATH"

log "Final Gatekeeper assessment for DMG"
spctl --assess --type open --verbose=4 "$DMG_PATH" || true

log "Done"
echo "DMG ready: $DMG_PATH"
