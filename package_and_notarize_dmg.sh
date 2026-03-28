#!/bin/bash
set -euo pipefail

########################################
# Config
########################################

APP_PATH="/Users/hotxiang/Desktop/Mumble.app"
DMG_PATH="/Users/hotxiang/Desktop/Mumble.dmg"
VOL_NAME="Mumble"
KEYCHAIN_PROFILE="mumble-notary"

########################################
# Helpers
########################################

log() {
  echo
  echo "==> $1"
}

fail() {
  echo
  echo "ERROR: $1" >&2
  exit 1
}

########################################
# Checks
########################################

[ -d "$APP_PATH" ] || fail "App not found: $APP_PATH"

if ! xcrun --find notarytool >/dev/null 2>&1; then
  fail "notarytool not found. Please install Xcode command line tools."
fi

if ! xcrun --find stapler >/dev/null 2>&1; then
  fail "stapler not found. Please install Xcode command line tools."
fi

########################################
# 1) Staple the already-notarized app
########################################

log "Stapling app"
xcrun stapler staple "$APP_PATH"

log "Validating app staple"
xcrun stapler validate "$APP_PATH"

########################################
# 2) Verify app before packaging
########################################

log "Verifying app code signature"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

log "Assessing app with Gatekeeper"
spctl --assess --type execute --verbose=4 "$APP_PATH"

########################################
# 3) Remove old DMG if exists
########################################

if [ -f "$DMG_PATH" ]; then
  log "Removing old DMG"
  rm -f "$DMG_PATH"
fi

########################################
# 4) Create compressed read-only DMG
########################################

log "Creating DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

[ -f "$DMG_PATH" ] || fail "DMG was not created: $DMG_PATH"

########################################
# 5) Submit DMG for notarization
########################################

log "Submitting DMG for notarization"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

########################################
# 6) Staple the notarized DMG
########################################

log "Stapling DMG"
xcrun stapler staple "$DMG_PATH"

log "Validating DMG staple"
xcrun stapler validate "$DMG_PATH"

########################################
# 7) Final checks
########################################

log "Final Gatekeeper assessment for DMG"
spctl --assess --type open --verbose=4 "$DMG_PATH" || true

log "Done"
echo "DMG ready: $DMG_PATH"
