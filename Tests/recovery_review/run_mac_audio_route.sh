#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-audio-route.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -O1 -g -Wall -Wextra -Werror \
  -framework Foundation -framework CoreAudio \
  "$TASK_REPO_ROOT/Tests/recovery_review/mac_audio_route.m" \
  -o "$TASK_BUILD_DIR/mac-audio-route"
"$TASK_BUILD_DIR/mac-audio-route" "$@"
