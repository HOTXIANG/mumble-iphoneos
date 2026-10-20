#!/bin/bash
# Build the current checkout, export Developer ID code, and produce a notarized DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEAM_ID="${TEAM_ID:-5Q255DK223}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mumble-notary}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/distribution}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-60m}"
INPUT_APP=""
CHECK_ONLY=0
RUN_DIR=""

usage() {
  cat <<'EOF'
Usage: ./package_and_notarize_dmg.sh [options] [exported.app]

With no app argument, build the current working tree as a Universal Release
archive, then export it with Developer ID signing. No git pull/reset is performed.

Options:
  --check                      Check signing/notarization prerequisites only
  --app PATH                   Package an existing Developer ID-exported app
  --team-id ID                 Apple Developer team (default: 5Q255DK223)
  --keychain-profile NAME      notarytool credentials (default: mumble-notary)
  --output-dir DIR             Output folder (default: build/distribution)
  --export-options-plist FILE  Custom Developer ID export options, e.g. for CI
  -h, --help                   Show help

Environment equivalents: TEAM_ID, NOTARY_PROFILE, OUTPUT_DIR,
EXPORT_OPTIONS_PLIST, NOTARY_TIMEOUT (default 60m), NOTARY_KEYCHAIN (optional).

One-time setup is documented in docs/MACOS_DISTRIBUTION.md.
The default build needs Xcode account access, an Apple Development identity,
a Developer ID Application identity with its private key, and notary credentials.
EOF
}

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
require_value() { [[ $# -ge 2 && -n "$2" ]] || fail "$1 needs a value"; }
on_exit() {
  local exit_status=$?
  if [[ $exit_status -ne 0 && -n "$RUN_DIR" ]]; then
    printf '\nPackaging failed. Build and notarization logs: %s\n' "$RUN_DIR" >&2
    printf 'No verified release was produced by this run.\n' >&2
  fi
}
trap on_exit EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --app) require_value "$@"; [[ -z "$INPUT_APP" ]] || fail "Only one app may be supplied"; INPUT_APP="$2"; shift 2 ;;
    --team-id) require_value "$@"; TEAM_ID="$2"; shift 2 ;;
    --keychain-profile) require_value "$@"; NOTARY_PROFILE="$2"; shift 2 ;;
    --output-dir) require_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --export-options-plist) require_value "$@"; EXPORT_OPTIONS_PLIST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) fail "Unknown option: $1 (use --help)" ;;
    *) [[ -z "$INPUT_APP" ]] || fail "Only one app may be supplied"; INPUT_APP="$1"; shift ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Run this script on macOS with full Xcode installed."
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Invalid Team ID: $TEAM_ID"
for tool in xcodebuild xcrun security codesign hdiutil ditto spctl python3 shasum; do
  command -v "$tool" >/dev/null || fail "Required tool is missing: $tool"
done
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
[[ -f "$ROOT_DIR/Scripts/macos_distribution.py" ]] || fail "Missing distribution verification helper"

if [[ -n "$INPUT_APP" ]]; then
  [[ -d "$INPUT_APP/Contents" && "$INPUT_APP" == *.app ]] || fail "Not a macOS .app bundle: $INPUT_APP"
  INPUT_APP="$(cd "$(dirname "$INPUT_APP")" && pwd)/$(basename "$INPUT_APP")"
fi
if [[ -n "$EXPORT_OPTIONS_PLIST" ]]; then
  [[ -f "$EXPORT_OPTIONS_PLIST" ]] || fail "Export options not found: $EXPORT_OPTIONS_PLIST"
  EXPORT_OPTIONS_PLIST="$(cd "$(dirname "$EXPORT_OPTIONS_PLIST")" && pwd)/$(basename "$EXPORT_OPTIONS_PLIST")"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_OPTIONS_PLIST")" == developer-id ]] || fail "Export method must be developer-id"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_OPTIONS_PLIST")" == "$TEAM_ID" ]] || fail "Export options teamID must match $TEAM_ID"
fi

log "Checking local signing identities"
IDENTITIES="$(security find-identity -v -p codesigning)"
DEVELOPER_ID_IDENTITIES="$(printf '%s\n' "$IDENTITIES" | awk -v team="$TEAM_ID" 'index($0, "\"Developer ID Application:") && index($0, "(" team ")\"")')"
[[ -n "$DEVELOPER_ID_IDENTITIES" ]] || fail "No valid Developer ID Application identity with private key for team $TEAM_ID. Install it in Keychain Access; Apple Development / Apple Distribution cannot replace it."
if [[ -z "$INPUT_APP" ]]; then
  printf '%s\n' "$IDENTITIES" | awk '/"(Apple Development:|Mac Developer:)/ { found=1 } END { exit !found }' || fail "The archive step needs an Apple Development identity. Install one through Xcode Accounts, or use --app with an app already exported for Developer ID."
fi

NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi
log "Checking notarization credentials ($NOTARY_PROFILE)"
xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format plist >/dev/null || fail "Cannot authenticate to Apple's notary service. Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\""
if [[ "$CHECK_ONLY" == 1 ]]; then
  log "Prerequisites found. Xcode will resolve the app and widget provisioning profiles during archive/export."
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
RUN_DIR="$(mktemp -d "$OUTPUT_DIR/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
EXPORT_DIR="$RUN_DIR/Export"
mkdir -p "$EXPORT_DIR"

if [[ -z "$INPUT_APP" ]]; then
  [[ -f "$ROOT_DIR/MumbleKit/src/MKConnection.m" ]] || fail "MumbleKit submodule is missing. Run git submodule update --init --recursive."
  ARCHIVE_PATH="$RUN_DIR/Mumble.xcarchive"
  log "Archiving the current source (Release, arm64 + x86_64)"
  xcodebuild -project "$ROOT_DIR/Mumble.xcodeproj" -scheme Mumble \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$RUN_DIR/DerivedData" -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    "DEVELOPMENT_TEAM=$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    'CODE_SIGN_IDENTITY=Apple Development' \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
    ENABLE_HARDENED_RUNTIME=YES ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    'SWIFT_OPTIMIZATION_LEVEL=-O' archive 2>&1 | tee "$RUN_DIR/archive.log"

  if [[ -z "$EXPORT_OPTIONS_PLIST" ]]; then
    EXPORT_OPTIONS_PLIST="$RUN_DIR/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
  fi
  log "Exporting Developer ID app and widget signatures/provisioning profiles"
  xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates 2>&1 | tee "$RUN_DIR/export.log"
  APP_PATH="$EXPORT_DIR/Mumble.app"
else
  APP_PATH="$EXPORT_DIR/$(basename "$INPUT_APP")"
  log "Copying exported app (the original is preserved)"
  ditto "$INPUT_APP" "$APP_PATH"
fi
[[ -d "$APP_PATH/Contents" ]] || fail "Exported app was not found: $APP_PATH"

# Use the actual export certificate, so re-signing retains profile authorization
# even when the keychain has multiple Developer ID certificates for this team.
SIGNING_IDENTITY="$(python3 "$ROOT_DIR/Scripts/macos_distribution.py" signing-identity "$APP_PATH" "$TEAM_ID")"
printf '%s\n' "$DEVELOPER_ID_IDENTITIES" | awk -v identity="$SIGNING_IDENTITY" 'index($0, identity) { found=1 } END { exit !found }' || fail "The private key for the exported app's Developer ID certificate is unavailable."
log "Applying secure timestamps and hardened runtime to all nested code"
python3 "$ROOT_DIR/Scripts/macos_distribution.py" resign "$APP_PATH" "$SIGNING_IDENTITY" 2>&1 | tee "$RUN_DIR/signing.log"
python3 "$ROOT_DIR/Scripts/macos_distribution.py" verify "$APP_PATH" "$TEAM_ID" 2>&1 | tee "$RUN_DIR/verification.log"

APP_NAME="$(basename "$APP_PATH" .app)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
[[ "$APP_VERSION" =~ ^[A-Za-z0-9._-]+$ && "$APP_BUILD" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Unsafe version/build in Info.plist"
DMG_NAME="$APP_NAME-$APP_VERSION-$APP_BUILD-universal.dmg"
FINAL_DMG="$OUTPUT_DIR/$DMG_NAME"
[[ ! -e "$FINAL_DMG" && ! -e "$FINAL_DMG.sha256" ]] || fail "Release already exists: $FINAL_DMG. Choose a new output folder or increment the app version/build."

notarize() {
  local artifact="$1" label="$2" submit_exit=0 submission_id status
  log "Submitting $label for Apple notarization (timeout: $NOTARY_TIMEOUT)"
  xcrun notarytool submit "$artifact" "${NOTARY_ARGS[@]}" --wait \
    --timeout "$NOTARY_TIMEOUT" --output-format plist \
    > "$RUN_DIR/$label-notary.plist" 2> "$RUN_DIR/$label-notary.stderr" || submit_exit=$?
  cat "$RUN_DIR/$label-notary.stderr" >&2
  submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$RUN_DIR/$label-notary.plist" 2>/dev/null || true)"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$RUN_DIR/$label-notary.plist" 2>/dev/null || true)"
  if [[ "$submit_exit" != 0 || "$status" != Accepted ]]; then
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" "$RUN_DIR/$label-notary-log.json" || true
      printf 'Submission ID: %s\n' "$submission_id" >&2
      printf 'For a pending submission, check: xcrun notarytool info %s --keychain-profile "%s"\n' "$submission_id" "$NOTARY_PROFILE" >&2
    fi
    fail "$label notarization did not succeed (status: ${status:-unknown}, exit: $submit_exit). See $RUN_DIR/$label-notary*"
  fi
  printf '%s notarization: Accepted (%s)\n' "$label" "$submission_id"
}

log "Preparing app notarization upload"
ditto -c -k --keepParent "$APP_PATH" "$RUN_DIR/$APP_NAME.zip"
notarize "$RUN_DIR/$APP_NAME.zip" app
# A ZIP cannot carry a stapled ticket; staple and assess the contained app.
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1 | tee "$RUN_DIR/app-gatekeeper.log"

log "Creating drag-to-Applications disk image"
STAGING_DIR="$RUN_DIR/DMG"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
DMG_PATH="$RUN_DIR/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -fs HFS+ -format UDZO "$DMG_PATH"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
notarize "$DMG_PATH" dmg
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" 2>&1 | tee "$RUN_DIR/dmg-gatekeeper.log"

# Expose a release only after all signing, notarization and policy checks pass.
(cd "$RUN_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
# Both paths are on the same filesystem. Atomic links prevent another run's
# release/checksum from being overwritten between the earlier check and now.
python3 - "$DMG_PATH" "$FINAL_DMG" <<'PY'
import os
import sys

source, destination = sys.argv[1:]
created_dmg = False
try:
    os.link(source, destination)
    created_dmg = True
    os.link(source + ".sha256", destination + ".sha256")
except OSError as error:
    if created_dmg:
        os.unlink(destination)
    raise SystemExit(f"Cannot publish release without overwriting an existing file: {error}")
PY
log "Verified release ready"
printf 'DMG: %s\nSHA-256: %s.sha256\nLogs and archive: %s\n' "$FINAL_DMG" "$FINAL_DMG" "$RUN_DIR"
