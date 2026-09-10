#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TRANSPORT_TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/mumble-transport-tests.XXXXXX")"
trap 'rm -rf "$TRANSPORT_TEST_BUILD"' EXIT HUP INT TERM
xcrun clang -fno-objc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I MumbleKit/src -framework Foundation \
    Tests/Native/MKConnectionTransportTests.m -o "$TRANSPORT_TEST_BUILD/transport-tests"
"$TRANSPORT_TEST_BUILD/transport-tests"
