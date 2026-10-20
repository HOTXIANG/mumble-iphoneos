#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TASK_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mumble-chain-presets.XXXXXX")
trap 'rm -rf "$TASK_BUILD_DIR"' EXIT HUP INT TERM
xcrun --sdk macosx swiftc -swift-version 6 \
  -module-cache-path "$TASK_BUILD_DIR/modules" \
  "$TASK_REPO_ROOT/Source/Classes/SwiftUI/Preferences/AudioPluginChainPresets.swift" \
  "$TASK_REPO_ROOT/Tests/audio_plugins/chain_preset_tests.swift" \
  -o "$TASK_BUILD_DIR/chain-preset-tests"
"$TASK_BUILD_DIR/chain-preset-tests"
