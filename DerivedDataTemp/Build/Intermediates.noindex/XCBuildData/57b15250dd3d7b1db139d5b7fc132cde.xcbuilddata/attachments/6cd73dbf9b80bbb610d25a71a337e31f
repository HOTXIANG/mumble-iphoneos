#!/bin/sh
# Re-sign nested dylibs inside MumbleKit.framework so Team IDs match the app
if [ "${CODE_SIGNING_ALLOWED}" != "YES" ]; then
  echo "Code signing not allowed for this build; skipping re-sign."
  exit 0
fi

if [ -z "${EXPANDED_CODE_SIGN_IDENTITY}" ]; then
  echo "No signing identity available; skipping re-sign."
  exit 0
fi

MK_FRAMEWORKS="${CODESIGNING_FOLDER_PATH}/Contents/Frameworks/MumbleKit.framework"
if [ ! -d "$MK_FRAMEWORKS" ] && [ -n "${FRAMEWORKS_FOLDER_PATH}" ]; then
  MK_FRAMEWORKS="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/MumbleKit.framework"
fi

echo "Looking for nested dylibs in: $MK_FRAMEWORKS"
if [ -d "$MK_FRAMEWORKS" ]; then
  for dylib in "$MK_FRAMEWORKS"/Versions/A/Frameworks/*.dylib; do
    if [ -f "$dylib" ]; then
      echo "Re-signing $dylib"
      /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none --preserve-metadata=identifier,entitlements "$dylib"
    fi
  done
  # Re-sign the framework itself to update the seal
  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none --preserve-metadata=identifier,entitlements "$MK_FRAMEWORKS"
else
  echo "MumbleKit.framework not found at $MK_FRAMEWORKS"
fi

