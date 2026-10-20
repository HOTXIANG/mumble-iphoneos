#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-certificate-background.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -O1 -g -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$TASK_REPO_ROOT/Source/Classes" \
  -framework Foundation -framework Security \
  "$TASK_REPO_ROOT/Tests/recovery_review/certificate_background_tests.m" \
  -o "$TASK_BUILD_DIR/certificate-background-tests"
"$TASK_BUILD_DIR/certificate-background-tests"
