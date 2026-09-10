#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-recovery-swift.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -module-cache-path "$TASK_BUILD_DIR/modules" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/Core/AsyncWrappers/ConnectionAsync.swift" \
  "$TASK_REPO_ROOT/Tests/recovery_review/ConnectionAsyncHarness.swift" \
  -o "$TASK_BUILD_DIR/connection-async-harness"
"$TASK_BUILD_DIR/connection-async-harness"
