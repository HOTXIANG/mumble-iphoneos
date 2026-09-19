#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-mac-audio-recovery.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx clang -std=c11 -O1 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$TASK_REPO_ROOT/MumbleKit/src" \
  "$TASK_REPO_ROOT/Tests/recovery_review/mac_audio_recovery_tests.c" \
  -o "$TASK_BUILD_DIR/mac-audio-recovery-tests"
"$TASK_BUILD_DIR/mac-audio-recovery-tests"
