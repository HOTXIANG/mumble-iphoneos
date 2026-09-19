#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-server-pinger.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fno-objc-arc -fblocks -O1 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$TASK_REPO_ROOT/MumbleKit/src/MumbleKit" \
  -framework Foundation \
  "$TASK_REPO_ROOT/MumbleKit/src/MKServerPinger.m" \
  "$TASK_REPO_ROOT/Tests/recovery_review/server_pinger_tests.m" \
  -o "$TASK_BUILD_DIR/server-pinger-tests"
"$TASK_BUILD_DIR/server-pinger-tests"
