#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-audio-health.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
TASK_SANITIZER=address,undefined
case "${1:-}" in
  '') ;;
  --thread-sanitizer) TASK_SANITIZER=thread ;;
  *) echo "usage: $0 [--thread-sanitizer]" >&2; exit 2 ;;
esac
xcrun --sdk macosx clang -std=c11 -O1 -g -Wall -Wextra -Werror -pthread \
  -fsanitize="$TASK_SANITIZER" -fno-omit-frame-pointer \
  -I "$TASK_REPO_ROOT/MumbleKit/src" \
  "$TASK_REPO_ROOT/Tests/recovery_review/audio_health_tests.c" \
  -o "$TASK_BUILD_DIR/audio-health-tests"
"$TASK_BUILD_DIR/audio-health-tests"
