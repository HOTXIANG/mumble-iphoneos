#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-session-recovery.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
awk '
    /^- \(void\)stopAudioDeviceGraphLockedNotifyingOthers:\(BOOL\)notifyOthers \{/ { emit = 1 }
    emit { print }
    emit && /^}/ { exit }
' "$TASK_REPO_ROOT/MumbleKit/src/MKAudio.m" > "$TASK_BUILD_DIR/MKAudioGraphStop.inc"
test -s "$TASK_BUILD_DIR/MKAudioGraphStop.inc"
xcrun --sdk macosx clang -fobjc-arc -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer -framework Foundation \
    -I "$TASK_BUILD_DIR" "$TASK_REPO_ROOT/Tests/recovery_review/audio_session_recovery_tests.m" \
    -o "$TASK_BUILD_DIR/audio-session-recovery-tests"
"$TASK_BUILD_DIR/audio-session-recovery-tests"
