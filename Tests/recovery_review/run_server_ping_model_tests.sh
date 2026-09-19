#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-server-ping-model.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
TASK_TEST_ROOT="$TASK_REPO_ROOT/Tests/recovery_review"
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
  -c "$TASK_TEST_ROOT/server_ping_model_stub.m" \
  -o "$TASK_BUILD_DIR/server-ping-model-stub.o"
xcrun --sdk macosx swiftc -swift-version 5 \
  -module-cache-path "$TASK_BUILD_DIR/modules" \
  -import-objc-header "$TASK_TEST_ROOT/server_ping_model_stub.h" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/Models/ServerPingModel.swift" \
  "$TASK_TEST_ROOT/server_ping_model_tests.swift" \
  "$TASK_BUILD_DIR/server-ping-model-stub.o" \
  -o "$TASK_BUILD_DIR/server-ping-model-tests"
"$TASK_BUILD_DIR/server-ping-model-tests"
