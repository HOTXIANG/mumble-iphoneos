// Exercise the production route policy without opening audio devices or a server.
#include "MKAudioMacRecovery.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned long checks;
#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
        exit(EXIT_FAILURE); \
    } \
} while (0)

static MKAudioMacRouteState built_in_route(void) {
    return (MKAudioMacRouteState) {
        .input = { .deviceID = 41, .alive = 1, .channels = 1, .sampleRate = 48000 },
        .output = { .deviceID = 42, .alive = 1, .channels = 2, .sampleRate = 48000 },
    };
}

static void check_restart_for_every_backend(MKAudioMacRouteState previous,
                                             MKAudioMacRouteState current) {
    CHECK(!MKAudioMacRouteEqual(previous, current));
    CHECK(!MKAudioMacRouteEqual(current, previous));
    CHECK(MKAudioMacRouteNeedsRestart(previous, current, false, false));
    CHECK(MKAudioMacRouteNeedsRestart(previous, current, false, true));
    CHECK(MKAudioMacRouteNeedsRestart(previous, current, true, false));
    CHECK(MKAudioMacRouteNeedsRestart(previous, current, true, true));
}

static void test_private_device_notifications_preserve_live_route(void) {
    const MKAudioMacRouteState configured = built_in_route();
    unsigned restarts = 0;
    for (unsigned event = 0; event < 100; ++event) {
        // VPIO creates/removes private devices. Re-querying the selected hardware
        // after these list notifications still yields the same effective route.
        const MKAudioMacRouteState current = built_in_route();
        CHECK(MKAudioMacRouteEqual(configured, current));
        if (MKAudioMacRouteNeedsRestart(configured, current, true, true)) ++restarts;
        CHECK(!MKAudioMacRouteNeedsRestart(configured, current, false, true));
        // Missing callback activity is handled by its own watchdog; an unchanged
        // device-list notification must not create a competing recovery chain.
        CHECK(!MKAudioMacRouteNeedsRestart(configured, current, true, false));
    }
    CHECK(restarts == 0);
}

static void test_hardware_switch_and_disappearance(void) {
    const MKAudioMacRouteState configured = built_in_route();
    MKAudioMacRouteState current = configured;
    current.input.deviceID = 71;
    check_restart_for_every_backend(configured, current);
    current = configured;
    current.output.deviceID = 72;
    check_restart_for_every_backend(configured, current);

    current = configured;
    current.input.alive = 0;
    check_restart_for_every_backend(configured, current);
    check_restart_for_every_backend(current, configured);
    current = configured;
    current.output.alive = 0;
    check_restart_for_every_backend(configured, current);
    check_restart_for_every_backend(current, configured);

    current = configured;
    current.input = (MKAudioMacDeviceState) { 0 };
    check_restart_for_every_backend(configured, current);
    current = configured;
    current.output = (MKAudioMacDeviceState) { 0 };
    check_restart_for_every_backend(configured, current);
}

static void check_format_change(MKAudioMacRouteState configured,
                               MKAudioMacRouteState current) {
    CHECK(!MKAudioMacRouteEqual(configured, current));
    // HAL needs its client format rebuilt. A live VPIO graph performs its own
    // conversion; unhealthy VPIO must still be allowed to recover.
    CHECK(MKAudioMacRouteNeedsRestart(configured, current, false, true));
    CHECK(MKAudioMacRouteNeedsRestart(configured, current, false, false));
    CHECK(MKAudioMacRouteNeedsRestart(configured, current, true, false));
    CHECK(!MKAudioMacRouteNeedsRestart(configured, current, true, true));
}

static void test_format_changes_use_backend_and_callback_health(void) {
    const MKAudioMacRouteState configured = built_in_route();
    MKAudioMacRouteState current = configured;
    current.input.sampleRate = 44100;
    check_format_change(configured, current);
    current = configured;
    current.output.sampleRate = 96000;
    check_format_change(configured, current);
    current = configured;
    current.input.channels = 3;
    check_format_change(configured, current);
    current = configured;
    current.output.channels = 1;
    check_format_change(configured, current);

    // A same-ID device that is unavailable cannot use VPIO's healthy-callback
    // exception, including stale callbacks left from just before device loss.
    MKAudioMacRouteState unavailable = configured;
    unavailable.input.alive = 0;
    current = unavailable;
    current.input.sampleRate = 44100;
    CHECK(MKAudioMacRouteNeedsRestart(unavailable, current, true, true));
    unavailable = configured;
    unavailable.output.alive = 0;
    current = unavailable;
    current.output.channels = 1;
    CHECK(MKAudioMacRouteNeedsRestart(unavailable, current, true, true));
}

static void test_vpio_settling_and_later_user_switch(void) {
    MKAudioMacRouteState configured = built_in_route();
    MKAudioMacRouteState settled = configured;
    settled.input.channels = 3;
    settled.output.sampleRate = 44100;
    CHECK(!MKAudioMacRouteNeedsRestart(configured, settled, true, true));
    // Accept the live VPIO configuration as the new baseline. Queued tail
    // notifications must not repeatedly rebuild the just-started graph.
    configured = settled;
    for (unsigned event = 0; event < 100; ++event) {
        CHECK(!MKAudioMacRouteNeedsRestart(configured, settled, true, true));
    }
    settled.output.deviceID = 82;
    CHECK(MKAudioMacRouteNeedsRestart(configured, settled, true, true));
    configured = settled;
    CHECK(!MKAudioMacRouteNeedsRestart(configured, settled, true, true));
}

static void test_device_switch_during_start_keeps_old_baseline(void) {
    const MKAudioMacRouteState setup = built_in_route();
    MKAudioMacRouteState afterStart = setup;
    afterStart.input.deviceID = 71;
    // HAL can still be bound to the previously selected microphone. Treating
    // the new global default as already configured would swallow its event.
    MKAudioMacRouteState baseline = MKAudioMacRouteAfterStart(setup, afterStart);
    CHECK(MKAudioMacRouteEqual(baseline, setup));
    CHECK(MKAudioMacRouteNeedsRestart(baseline, afterStart, false, true));

    afterStart = setup;
    afterStart.output.deviceID = 72;
    baseline = MKAudioMacRouteAfterStart(setup, afterStart);
    CHECK(MKAudioMacRouteEqual(baseline, setup));
    CHECK(MKAudioMacRouteNeedsRestart(baseline, afterStart, false, true));

    afterStart = setup;
    afterStart.input.sampleRate = 44100;
    afterStart.input.channels = 3;
    // With unchanged devices, synchronous VPIO setup changes belong to the
    // running graph; its pending notifications should compare equal.
    baseline = MKAudioMacRouteAfterStart(setup, afterStart);
    CHECK(MKAudioMacRouteEqual(baseline, afterStart));
    CHECK(!MKAudioMacRouteNeedsRestart(baseline, afterStart, true, true));
}

int main(void) {
    test_private_device_notifications_preserve_live_route();
    test_hardware_switch_and_disappearance();
    test_format_changes_use_backend_and_callback_health();
    test_vpio_settling_and_later_user_switch();
    test_device_switch_during_start_keeps_old_baseline();
    printf("macOS audio recovery policy: %lu checks passed (no audio IO).\n", checks);
    return EXIT_SUCCESS;
}
