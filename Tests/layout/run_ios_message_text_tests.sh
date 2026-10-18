#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-ios-message-text.XXXXXX")
TASK_SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
TASK_ARCH=$(uname -m)
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
# Mac Catalyst loads the production UIKit text view without a simulator.
xcrun --sdk macosx swiftc -swift-version 5 \
  -target "$TASK_ARCH-apple-ios17.0-macabi" \
  -sdk "$TASK_SDK_PATH" \
  -F "$TASK_SDK_PATH/System/iOSSupport/System/Library/Frameworks" \
  -module-cache-path "$TASK_BUILD_DIR/modules" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/Channel/MessageBodyTextView.swift" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/Channel/IOSMessageTextView.swift" \
  "$TASK_REPO_ROOT/Tests/layout/ios_message_text_tests.swift" \
  -o "$TASK_BUILD_DIR/ios-message-text-tests"
"$TASK_BUILD_DIR/ios-message-text-tests"
