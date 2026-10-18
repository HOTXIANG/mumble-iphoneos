#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-message-text.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx swiftc -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$TASK_BUILD_DIR/modules" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/Channel/MessageBodyTextView.swift" \
  "$TASK_REPO_ROOT/Tests/layout/message_text_tests.swift" \
  -o "$TASK_BUILD_DIR/message-text-tests"
"$TASK_BUILD_DIR/message-text-tests"
