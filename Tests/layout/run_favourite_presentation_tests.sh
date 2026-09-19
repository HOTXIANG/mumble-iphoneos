#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-favourite-layout.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx swiftc -swift-version 5 \
  -module-cache-path "$TASK_BUILD_DIR/modules" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/MumbleNavigationView.swift" \
  "$TASK_REPO_ROOT/Tests/layout/favourite_presentation_tests.swift" \
  -o "$TASK_BUILD_DIR/favourite-presentation-tests"
"$TASK_BUILD_DIR/favourite-presentation-tests"
